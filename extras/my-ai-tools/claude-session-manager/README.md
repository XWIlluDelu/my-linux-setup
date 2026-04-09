# Claude Code Session Manager

A local web UI for browsing, searching, and managing your [Claude Code](https://claude.ai/code) session history.

![Dark terminal-style UI showing a searchable table of Claude Code sessions]()

## What it does

Reads from `~/.claude/` and exposes a browsable interface over all recorded sessions:

- **Search** across session titles, project paths, and prompt content
- **Sort** by recency, title, project, or conversation length
- **Inspect** any session — view project path, first/last prompts, timestamps, storage size
- **Delete** sessions with two-step confirmation (removes transcript + runtime sidecars + history entries)
- **Bilingual UI** — toggles between 中文 and English

## Usage

```bash
# Start the server
./run.sh

# Open in browser
open http://127.0.0.1:8765

# Stop the server
./stop.sh
```

The server runs on `127.0.0.1:8765` by default. Override with environment variables:

```bash
SESSION_MANAGER_HOST=0.0.0.0 SESSION_MANAGER_PORT=9000 ./run.sh
```

Logs go to `/tmp/session-manager.log`.

## Requirements

- Python 3.8+
- Claude Code installed (data lives in `~/.claude/`)

No external Python dependencies — uses only the standard library.

## Architecture

```
session_manager_server.py   Python HTTP server + data processing
session-manager.html        Single-page frontend (vanilla JS, no build step)
run.sh / stop.sh            Process management scripts
```

### API

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/` | Serves the UI |
| `GET` | `/api/sessions` | Returns all sessions as JSON |
| `DELETE` | `/api/sessions/{id}` | Deletes a session and all associated files |

### Data sources

The server reads three locations:

| Path | Content |
|------|---------|
| `~/.claude/projects/**/*.jsonl` | Conversation transcripts (primary) |
| `~/.claude/history.jsonl` | Structured session metadata index |
| `~/.claude/sessions/*.json` | Runtime sidecar files (cwd, pid, entrypoint) |

### Session title resolution

Titles are resolved in priority order:

1. **`explicit:ai-title`** — AI-generated title from `ai-title` record in transcript
2. **`derived:first-prompt`** — First qualifying user message (truncated to 72 chars)
3. **`derived:slug`** — Session slug from transcript metadata
4. **`derived:session-id`** — Fallback: `Session <first 8 chars of ID>`

The frontend shows a small badge (`ai` vs `derived`) next to each title.
