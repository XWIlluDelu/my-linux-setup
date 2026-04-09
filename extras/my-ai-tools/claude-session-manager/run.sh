#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_FILE="$ROOT_DIR/session-manager.pid"
LOG_FILE="${TMPDIR:-/tmp}/session-manager.log"
HOST="${SESSION_MANAGER_HOST:-127.0.0.1}"
PORT="${SESSION_MANAGER_PORT:-8765}"

if [[ -f "$PID_FILE" ]]; then
  existing_pid="$(cat "$PID_FILE")"
  if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
    printf 'Session manager is already running at http://%s:%s (PID %s)\n' "$HOST" "$PORT" "$existing_pid"
    exit 0
  fi
  rm -f "$PID_FILE"
fi

python3 "$ROOT_DIR/session_manager_server.py" > "$LOG_FILE" 2>&1 &
server_pid=$!
printf '%s' "$server_pid" > "$PID_FILE"

printf 'Started Claude session manager at http://%s:%s\n' "$HOST" "$PORT"
printf 'PID: %s\n' "$server_pid"
printf 'Log: %s\n' "$LOG_FILE"
