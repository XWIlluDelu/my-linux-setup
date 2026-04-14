#!/usr/bin/env python3
from __future__ import annotations

import html
import json
import os
import re
import shutil
import sys
import tempfile
from dataclasses import dataclass
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import unquote, urlparse


ROOT = Path(__file__).resolve().parent
UI_PATH = ROOT / "session-manager.html"
CLAUDE_DIR = Path.home() / ".claude"
PROJECTS_DIR = CLAUDE_DIR / "projects"
HISTORY_PATH = CLAUDE_DIR / "history.jsonl"
SESSIONS_DIR = CLAUDE_DIR / "sessions"

COMMAND_TAG_RE = re.compile(r"<command-name>.*?</command-name>", re.DOTALL)
COMMAND_STDOUT_RE = re.compile(
    r"<local-command-stdout>.*?</local-command-stdout>", re.DOTALL
)
COMMAND_CAVEAT_RE = re.compile(
    r"<local-command-caveat>.*?</local-command-caveat>", re.DOTALL
)
COMMAND_MESSAGE_RE = re.compile(r"<command-message>.*?</command-message>", re.DOTALL)
COMMAND_ARGS_RE = re.compile(r"<command-args>.*?</command-args>", re.DOTALL)
GENERIC_TAG_RE = re.compile(r"<[^>]+>")
MULTISPACE_RE = re.compile(r"\s+")


@dataclass
class RuntimeSessionInfo:
    started_at: str | None = None
    cwd: str | None = None
    entrypoint: str | None = None
    kind: str | None = None
    pid: int | None = None


def iso_from_any_timestamp(value: Any) -> str | None:
    if value is None:
        return None
    if isinstance(value, (int, float)):
        try:
            return datetime.fromtimestamp(
                float(value) / 1000.0, tz=timezone.utc
            ).isoformat()
        except (OSError, OverflowError, ValueError):
            return None
    if isinstance(value, str):
        text = value.strip()
        if not text:
            return None
        if text.endswith("Z"):
            return text.replace("Z", "+00:00")
        return text
    return None


def parse_jsonl(path: Path) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    if not path.exists():
        return records
    with path.open("r", encoding="utf-8") as handle:
        for line in handle:
            text = line.strip()
            if not text:
                continue
            try:
                payload = json.loads(text)
            except json.JSONDecodeError:
                continue
            if isinstance(payload, dict):
                records.append(payload)
    return records


def derive_session_id(path: Path, records: list[dict[str, Any]]) -> str:
    for record in records:
        session_id = record.get("sessionId")
        if isinstance(session_id, str) and session_id.strip():
            return session_id.strip()
    return path.stem


def jsonl_size_bytes(path: Path) -> int | None:
    try:
        return path.stat().st_size
    except OSError:
        return None


def read_history_index() -> dict[str, list[dict[str, Any]]]:
    grouped: dict[str, list[dict[str, Any]]] = {}
    for entry in parse_jsonl(HISTORY_PATH):
        session_id = entry.get("sessionId")
        if isinstance(session_id, str) and session_id:
            grouped.setdefault(session_id, []).append(entry)
    return grouped


def read_runtime_index() -> dict[str, RuntimeSessionInfo]:
    grouped: dict[str, RuntimeSessionInfo] = {}
    if not SESSIONS_DIR.exists():
        return grouped
    for path in SESSIONS_DIR.glob("*.json"):
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        if not isinstance(payload, dict):
            continue
        session_id = payload.get("sessionId")
        if not isinstance(session_id, str) or not session_id:
            continue
        grouped[session_id] = RuntimeSessionInfo(
            started_at=iso_from_any_timestamp(payload.get("startedAt")),
            cwd=payload.get("cwd") if isinstance(payload.get("cwd"), str) else None,
            entrypoint=payload.get("entrypoint")
            if isinstance(payload.get("entrypoint"), str)
            else None,
            kind=payload.get("kind") if isinstance(payload.get("kind"), str) else None,
            pid=payload.get("pid") if isinstance(payload.get("pid"), int) else None,
        )
    return grouped


def flatten_message_content(content: Any) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        pieces: list[str] = []
        for item in content:
            if isinstance(item, str):
                pieces.append(item)
            elif isinstance(item, dict):
                item_type = item.get("type")
                if item_type == "text" and isinstance(item.get("text"), str):
                    pieces.append(item["text"])
        return "\n".join(piece for piece in pieces if piece)
    return ""


def clean_message_text(text: str) -> str:
    cleaned = COMMAND_CAVEAT_RE.sub(" ", text)
    cleaned = COMMAND_STDOUT_RE.sub(" ", cleaned)
    cleaned = COMMAND_TAG_RE.sub(" ", cleaned)
    cleaned = COMMAND_MESSAGE_RE.sub(" ", cleaned)
    cleaned = COMMAND_ARGS_RE.sub(" ", cleaned)
    cleaned = GENERIC_TAG_RE.sub(" ", cleaned)
    cleaned = html.unescape(cleaned)
    cleaned = MULTISPACE_RE.sub(" ", cleaned).strip()
    return cleaned


def looks_like_prompt(text: str) -> bool:
    if not text:
        return False
    lowered = text.lower().strip()
    if not lowered:
        return False
    # Slash commands (e.g. /resume, /model, /help, /init)
    if lowered.startswith("/"):
        return False
    # Bare command keywords
    if lowered in {
        "see ya!",
        "model",
        "effort",
        "exit",
        "resume",
        "login",
        "logout",
        "init",
        "review",
    }:
        return False
    if (
        lowered.startswith("set model to")
        or lowered.startswith("set effort level")
        or lowered.startswith("current effort level")
    ):
        return False
    if lowered.startswith("caveat:"):
        return False
    if lowered.startswith("file created successfully at:"):
        return False
    return True


def summarize_text(text: str, limit: int = 160) -> str:
    stripped = MULTISPACE_RE.sub(" ", text).strip()
    if len(stripped) <= limit:
        return stripped
    return stripped[: limit - 1].rstrip() + "…"


def history_prompt_candidates(entries: list[dict[str, Any]]) -> list[str]:
    prompts: list[str] = []
    for entry in entries:
        display = entry.get("display")
        if isinstance(display, str):
            cleaned = clean_message_text(display)
            if looks_like_prompt(cleaned):
                prompts.append(cleaned)
    return prompts


def summarize_subagent_file(path: Path) -> dict[str, Any] | None:
    records = parse_jsonl(path)
    if not records:
        return None

    updated_at: str | None = None
    assistant_count = 0
    user_message_count = 0

    for record in records:
        timestamp = iso_from_any_timestamp(record.get("timestamp"))
        if timestamp and (updated_at is None or timestamp > updated_at):
            updated_at = timestamp

        role = None
        message = record.get("message")
        if isinstance(message, dict):
            role = message.get("role")
        if role == "assistant":
            assistant_count += 1

        if record.get("type") != "user" or role != "user":
            continue

        raw_text = flatten_message_content(
            message.get("content") if isinstance(message, dict) else None
        )
        cleaned_text = clean_message_text(raw_text)
        if looks_like_prompt(cleaned_text):
            user_message_count += 1

    return {
        "entryCount": user_message_count + assistant_count,
        "userMessageCount": user_message_count,
        "assistantMessageCount": assistant_count,
        "updatedAt": updated_at,
        "storageBytes": jsonl_size_bytes(path) or 0,
    }


def dir_total_bytes(path: Path) -> int:
    """Recursively sum the sizes of all files under *path*."""
    total = 0
    if not path.exists() or not path.is_dir():
        return total
    for entry in path.rglob("*"):
        if entry.is_file():
            try:
                total += entry.stat().st_size
            except OSError:
                pass
    return total


def compute_session_dir_bytes(session_path: Path, session_id: str) -> int:
    """Return total bytes of all files inside the session-specific directory
    (e.g. ``{project_dir}/{sessionId}/``), which may contain ``subagents/``,
    ``tool-results/``, and any other session-scoped sub-directories."""
    total = 0
    seen: set[Path] = set()
    for subagents_dir in candidate_subagent_dirs(session_path, session_id):
        session_dir = subagents_dir.parent
        if session_dir in seen:
            continue
        seen.add(session_dir)
        total += dir_total_bytes(session_dir)
    return total


def candidate_subagent_dirs(session_path: Path, session_id: str) -> list[Path]:
    candidates: list[Path] = []
    seen: set[Path] = set()
    for candidate_name in (session_path.stem, session_id):
        session_dir = session_path.parent / candidate_name
        subagents_dir = session_dir / "subagents"
        if subagents_dir in seen:
            continue
        seen.add(subagents_dir)
        candidates.append(subagents_dir)
    return candidates


def collect_subagent_aggregate(
    session_path: Path, session_id: str
) -> dict[str, Any] | None:
    aggregate = {
        "subagentCount": 0,
        "subagentEntryCount": 0,
        "subagentUserMessageCount": 0,
        "subagentAssistantMessageCount": 0,
        "subagentUpdatedAt": None,
        "subagentStorageBytes": 0,
    }

    for subagents_dir in candidate_subagent_dirs(session_path, session_id):
        if not subagents_dir.exists() or not subagents_dir.is_dir():
            continue
        for subagent_path in sorted(subagents_dir.glob("*.jsonl")):
            summary = summarize_subagent_file(subagent_path)
            if not summary:
                continue
            aggregate["subagentCount"] += 1
            aggregate["subagentEntryCount"] += summary["entryCount"]
            aggregate["subagentUserMessageCount"] += summary["userMessageCount"]
            aggregate["subagentAssistantMessageCount"] += summary[
                "assistantMessageCount"
            ]
            aggregate["subagentStorageBytes"] += summary["storageBytes"]
            updated_at = summary["updatedAt"]
            if updated_at and (
                aggregate["subagentUpdatedAt"] is None
                or updated_at > aggregate["subagentUpdatedAt"]
            ):
                aggregate["subagentUpdatedAt"] = updated_at

    return aggregate if aggregate["subagentCount"] > 0 else None


def normalize_session_records(
    path: Path,
    session_id: str,
    records: list[dict[str, Any]],
    history_index: dict[str, list[dict[str, Any]]],
    runtime_index: dict[str, RuntimeSessionInfo],
    source_category: str,
) -> dict[str, Any] | None:
    if not records or not session_id:
        return None

    project_path: str | None = None
    started_at: str | None = None
    updated_at: str | None = None
    explicit_title: str | None = None
    slug: str | None = None
    last_prompt_marker: str | None = None
    user_prompts: list[str] = []
    assistant_count = 0
    user_message_count = 0

    for record in records:
        project_path = project_path or (
            record.get("cwd") if isinstance(record.get("cwd"), str) else None
        )

        timestamp = iso_from_any_timestamp(record.get("timestamp"))
        if timestamp:
            if started_at is None or timestamp < started_at:
                started_at = timestamp
            if updated_at is None or timestamp > updated_at:
                updated_at = timestamp

        record_slug = record.get("slug")
        if isinstance(record_slug, str) and record_slug.strip():
            slug = record_slug.strip()

        record_type = record.get("type")
        if record_type == "ai-title":
            title_candidate = record.get("aiTitle")
            if isinstance(title_candidate, str) and title_candidate.strip():
                explicit_title = title_candidate.strip()
        elif record_type == "last-prompt":
            prompt_candidate = record.get("lastPrompt")
            if isinstance(prompt_candidate, str) and prompt_candidate.strip():
                last_prompt_marker = clean_message_text(prompt_candidate)

        message = record.get("message")
        if record_type == "user" and message is None:
            raw_text = flatten_message_content(record.get("content"))
            cleaned_text = clean_message_text(raw_text)
            if looks_like_prompt(cleaned_text):
                user_message_count += 1
                user_prompts.append(cleaned_text)
            continue

        if not project_path and record_type == "tool_use":
            tool_input = record.get("tool_input")
            if isinstance(tool_input, dict):
                for _field in ("path", "file_path"):
                    _p = tool_input.get(_field)
                    if isinstance(_p, str) and _p.startswith("/"):
                        project_path = str(Path(_p).parent)
                        break

        role = None
        if isinstance(message, dict):
            role = message.get("role")
        if role == "assistant":
            assistant_count += 1
        if record_type != "user" or role != "user":
            continue

        raw_text = flatten_message_content(
            message.get("content") if isinstance(message, dict) else None
        )
        cleaned_text = clean_message_text(raw_text)
        if not looks_like_prompt(cleaned_text):
            continue
        user_message_count += 1
        user_prompts.append(cleaned_text)

    history_entries = history_index.get(session_id, [])
    history_prompts = history_prompt_candidates(history_entries)

    first_prompt = (
        user_prompts[0]
        if user_prompts
        else (history_prompts[0] if history_prompts else "")
    )
    last_prompt = (
        last_prompt_marker
        or (user_prompts[-1] if user_prompts else "")
        or (history_prompts[-1] if history_prompts else "")
    )

    runtime = runtime_index.get(session_id)
    if runtime:
        project_path = project_path or runtime.cwd
        started_at = started_at or runtime.started_at

    title_source = ""
    title = None
    if explicit_title:
        title = explicit_title
        title_source = "explicit:ai-title"
    elif first_prompt:
        title = summarize_text(first_prompt, limit=72)
        title_source = "derived:first-prompt"
    elif slug:
        title = slug.replace("-", " ")
        title_source = "derived:slug"
    else:
        title = f"Session {session_id[:8]}"
        title_source = "derived:session-id"

    conversational_entry_count = user_message_count + assistant_count
    storage_bytes = jsonl_size_bytes(path)

    return {
        "recordId": f"{source_category}:{session_id}",
        "sessionId": session_id,
        "sourceCategory": source_category,
        "title": title,
        "titleSource": title_source,
        "projectPath": project_path or "",
        "firstPrompt": summarize_text(first_prompt, limit=220) if first_prompt else "",
        "lastPrompt": summarize_text(last_prompt, limit=220) if last_prompt else "",
        "entryCount": conversational_entry_count,
        "userMessageCount": user_message_count,
        "assistantMessageCount": assistant_count,
        "startedAt": started_at,
        "updatedAt": updated_at or started_at,
        "sourcePath": str(path),
        "storageBytes": storage_bytes,
        "slug": slug or "",
        "runtime": {
            "entrypoint": runtime.entrypoint if runtime else None,
            "kind": runtime.kind if runtime else None,
            "pid": runtime.pid if runtime else None,
        },
        "subagentCount": 0,
        "subagentEntryCount": 0,
        "subagentUserMessageCount": 0,
        "subagentAssistantMessageCount": 0,
        "subagentUpdatedAt": None,
        "subagentStorageBytes": 0,
        "sessionDirStorageBytes": 0,
    }


def normalize_session_file(
    path: Path,
    history_index: dict[str, list[dict[str, Any]]],
    runtime_index: dict[str, RuntimeSessionInfo],
    source_category: str,
) -> dict[str, Any] | None:
    records = parse_jsonl(path)
    if not records:
        return None
    session_id = derive_session_id(path, records)
    return normalize_session_records(
        path, session_id, records, history_index, runtime_index, source_category
    )


def find_session_transcript_path(session_id: str) -> Path | None:
    if not PROJECTS_DIR.exists():
        return None

    for project_dir in PROJECTS_DIR.iterdir():
        if not project_dir.is_dir():
            continue
        candidate = project_dir / f"{session_id}.jsonl"
        if candidate.exists():
            return candidate

    for project_dir in PROJECTS_DIR.iterdir():
        if not project_dir.is_dir():
            continue
        for candidate in project_dir.glob("*.jsonl"):
            records = parse_jsonl(candidate)
            if records and derive_session_id(candidate, records) == session_id:
                return candidate

    return None


def compact_history_file(session_id: str) -> int:
    if not HISTORY_PATH.exists():
        return 0
    removed = 0
    temp_path = HISTORY_PATH.with_suffix(".jsonl.tmp")
    with (
        HISTORY_PATH.open("r", encoding="utf-8") as src,
        temp_path.open("w", encoding="utf-8") as dst,
    ):
        for line in src:
            stripped = line.strip()
            if not stripped:
                continue
            try:
                payload = json.loads(stripped)
            except json.JSONDecodeError:
                dst.write(line)
                continue
            if isinstance(payload, dict) and payload.get("sessionId") == session_id:
                removed += 1
                continue
            dst.write(line)
    temp_path.replace(HISTORY_PATH)
    return removed


@dataclass
class StagedPathMove:
    original_path: Path
    staged_path: Path


def stage_path_for_deletion(
    path: Path, staging_root: Path, prefix: str, index: int
) -> StagedPathMove:
    staged_path = staging_root / f"{index:04d}-{prefix}-{path.name}"
    path.replace(staged_path)
    return StagedPathMove(original_path=path, staged_path=staged_path)


def restore_staged_moves(staged_moves: list[StagedPathMove]) -> None:
    for move in reversed(staged_moves):
        if not move.staged_path.exists():
            continue
        move.original_path.parent.mkdir(parents=True, exist_ok=True)
        move.staged_path.replace(move.original_path)


def collect_session_dirs_to_delete(session_path: Path, session_id: str) -> list[Path]:
    session_dirs: list[Path] = []
    if PROJECTS_DIR not in session_path.parents:
        return session_dirs

    seen_session_dirs: set[Path] = set()
    for subagents_dir in candidate_subagent_dirs(session_path, session_id):
        session_dir = subagents_dir.parent
        if (
            session_dir in seen_session_dirs
            or not session_dir.exists()
            or not session_dir.is_dir()
        ):
            continue
        seen_session_dirs.add(session_dir)
        session_dirs.append(session_dir)
    return session_dirs


def collect_runtime_sidecars(session_id: str) -> list[Path]:
    matches: list[Path] = []
    if not SESSIONS_DIR.exists():
        return matches
    for path in SESSIONS_DIR.glob("*.json"):
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        if isinstance(payload, dict) and payload.get("sessionId") == session_id:
            matches.append(path)
    return matches


def delete_session_record(session_id: str) -> dict[str, Any]:
    transcript_path = find_session_transcript_path(session_id)
    if transcript_path is None:
        raise FileNotFoundError(f"No transcript found for session {session_id}")

    try:
        transcript_size = transcript_path.stat().st_size
    except OSError:
        transcript_size = None

    session_dirs = collect_session_dirs_to_delete(transcript_path, session_id)
    runtime_files = collect_runtime_sidecars(session_id)
    staged_moves: list[StagedPathMove] = []

    with tempfile.TemporaryDirectory(
        prefix="claude-session-delete-", dir=str(CLAUDE_DIR)
    ) as staging_dir:
        staging_root = Path(staging_dir)
        try:
            staged_moves.append(
                stage_path_for_deletion(transcript_path, staging_root, "transcript", 0)
            )
            next_index = 1
            for session_dir in session_dirs:
                staged_moves.append(
                    stage_path_for_deletion(
                        session_dir, staging_root, "session-dir", next_index
                    )
                )
                next_index += 1
            for runtime_file in runtime_files:
                staged_moves.append(
                    stage_path_for_deletion(
                        runtime_file, staging_root, "runtime", next_index
                    )
                )
                next_index += 1

            history_removed = compact_history_file(session_id)
        except Exception:
            restore_staged_moves(staged_moves)
            raise

    return {
        "recordId": f"claude:{session_id}",
        "sessionId": session_id,
        "sourceCategory": "claude",
        "deletedTranscript": str(transcript_path),
        "deletedTranscriptBytes": transcript_size,
        "deletedSubagentDirs": [str(path) for path in session_dirs],
        "deletedRuntimeFiles": [str(path) for path in runtime_files],
        "deletedHistoryEntries": history_removed,
    }


def load_sessions() -> list[dict[str, Any]]:
    history_index = read_history_index()
    runtime_index = read_runtime_index()

    sessions_by_id: dict[str, dict[str, Any]] = {}
    if PROJECTS_DIR.exists():
        for project_dir in sorted(PROJECTS_DIR.iterdir()):
            if not project_dir.is_dir():
                continue
            for session_path in sorted(project_dir.glob("*.jsonl")):
                normalized = normalize_session_file(
                    session_path, history_index, runtime_index, "claude"
                )
                if not normalized:
                    continue
                subagent_aggregate = collect_subagent_aggregate(
                    session_path, normalized["sessionId"]
                )
                if subagent_aggregate:
                    normalized.update(subagent_aggregate)
                session_dir_bytes = compute_session_dir_bytes(
                    session_path, normalized["sessionId"]
                )
                normalized["sessionDirStorageBytes"] = session_dir_bytes
                sessions_by_id.setdefault(normalized["recordId"], normalized)

    sessions = list(sessions_by_id.values())

    sessions.sort(
        key=lambda item: (
            item.get("updatedAt") or "",
            item.get("startedAt") or "",
            item.get("sessionId") or "",
        ),
        reverse=True,
    )
    return sessions


class SessionManagerHandler(BaseHTTPRequestHandler):
    server_version = "ClaudeSessionManager/0.1"

    def _write_json(self, payload: Any, status: HTTPStatus = HTTPStatus.OK) -> None:
        body = json.dumps(payload, ensure_ascii=False, indent=2).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _write_text(
        self,
        payload: str,
        status: HTTPStatus = HTTPStatus.OK,
        content_type: str = "text/plain; charset=utf-8",
    ) -> None:
        body = payload.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        if parsed.path == "/api/sessions":
            try:
                sessions = load_sessions()
            except Exception as exc:  # noqa: BLE001
                self._write_json(
                    {"error": f"Failed to load sessions: {exc}"},
                    status=HTTPStatus.INTERNAL_SERVER_ERROR,
                )
                return
            self._write_json({"sessions": sessions, "count": len(sessions)})
            return

        if parsed.path in {"/", "/index.html"}:
            if not UI_PATH.exists():
                self._write_text(
                    "session-manager.html not found", status=HTTPStatus.NOT_FOUND
                )
                return
            self._write_text(
                UI_PATH.read_text(encoding="utf-8"),
                content_type="text/html; charset=utf-8",
            )
            return

        self._write_text("Not Found", status=HTTPStatus.NOT_FOUND)

    def do_DELETE(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        if not parsed.path.startswith("/api/sessions/"):
            self._write_json({"error": "Not Found"}, status=HTTPStatus.NOT_FOUND)
            return

        session_id = unquote(parsed.path.rsplit("/", 1)[-1]).strip()
        if not session_id:
            self._write_json(
                {"error": "Missing session id"}, status=HTTPStatus.BAD_REQUEST
            )
            return

        try:
            result = delete_session_record(session_id)
        except FileNotFoundError as exc:
            self._write_json({"error": str(exc)}, status=HTTPStatus.NOT_FOUND)
            return
        except Exception as exc:  # noqa: BLE001
            self._write_json(
                {"error": f"Failed to delete session: {exc}"},
                status=HTTPStatus.INTERNAL_SERVER_ERROR,
            )
            return

        self._write_json({"ok": True, "result": result}, status=HTTPStatus.OK)

    def log_message(self, format: str, *args: Any) -> None:  # noqa: A003
        sys.stderr.write("[session-manager] " + (format % args) + "\n")


def main() -> None:
    port = int(os.environ.get("SESSION_MANAGER_PORT", "8765"))
    host = os.environ.get("SESSION_MANAGER_HOST", "127.0.0.1")
    server = ThreadingHTTPServer((host, port), SessionManagerHandler)
    print(f"Claude session manager available at http://{host}:{port}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down session manager.")
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
