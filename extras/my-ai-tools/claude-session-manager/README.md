# Claude Code Session Manager

A local browser for Claude Code transcripts under `~/.claude/`. Search titles, project paths and prompt previews; sort by date, project or conversation length; inspect storage use; or delete a session with two-click confirmation. The UI supports Chinese and English.

## Run

Requires Python 3.10+, Bash, `ps`, `seq`, and `nohup`. `lsof` is optional for occupied-port discovery and fallback stopping. No Python or frontend packages are required.

```bash
./run.sh --check
./run.sh --apply
xdg-open http://127.0.0.1:8765
./stop.sh --apply
```

Both wrappers default to `--check`. For foreground execution:

```bash
python3 session_manager_server.py --serve
```

`--serve` explicitly starts the deletion-capable API. Without it, the Python entry point prints a check summary.

Set `SESSION_MANAGER_PORT=9000` on both wrappers to use another port. `SESSION_MANAGER_HOST` accepts only `127.0.0.1` or `localhost`. The service checks Host/Origin headers, but has no user authentication: use it only on a trusted local account, not behind a public reverse proxy.

PID and log files live at `${XDG_STATE_HOME:-$HOME/.local/state}/claude-session-manager/server.pid` and `server.log`, created with a private umask.

## Deletion and recovery

Stop Claude sessions before deleting their records and keep a backup of `~/.claude/`. A deletion removes:

- the project's transcript JSONL;
- its session directory, including subagents and tool results;
- matching runtime sidecars;
- matching entries in `history.jsonl`.

The server rejects path-like IDs, ignores symlinked transcripts/directories, and refuses sessions whose runtime sidecar identifies a live process. Requests run serially to avoid concurrent history rewrites. Claude itself does not participate in this serialization; an unrecorded or restarting session can still write files, so close it first.

Files are staged before rewriting history. If that rewrite fails, they are restored. If restoration also fails, the error names a `~/.claude/claude-session-delete-*` recovery directory; keep it and recover the files manually. Successful deletion is permanent. A failed API request remains visible in the UI rather than being shown as deleted.

## API and data

| Method | Path | Action |
|---|---|---|
| `GET` | `/` | Serve `session-manager.html` |
| `GET` | `/api/sessions` | List normalized sessions |
| `DELETE` | `/api/sessions/{id}` | Delete one session and its associated data |

Transcripts are read from `~/.claude/projects/<project>/*.jsonl`, history from `~/.claude/history.jsonl`, and runtime metadata from `~/.claude/sessions/*.json`. These are Claude Code's internal file formats, not a stable public API.

Titles prefer `ai-title`, then the first qualifying user message, then a slug, then the session ID. Storage totals include transcript bytes and the session directory once; subagent totals are a breakdown, not additional bytes.
