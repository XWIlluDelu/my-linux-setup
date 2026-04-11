#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_FILE="$ROOT_DIR/session-manager.pid"
LOG_FILE="${TMPDIR:-/tmp}/session-manager.log"
HOST="${SESSION_MANAGER_HOST:-127.0.0.1}"
PORT="${SESSION_MANAGER_PORT:-8765}"
PROBE_HOST="$HOST"

if [[ "$PROBE_HOST" == "0.0.0.0" ]]; then
  PROBE_HOST="127.0.0.1"
fi

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

for _ in $(seq 1 50); do
  if ! kill -0 "$server_pid" 2>/dev/null; then
    rm -f "$PID_FILE"
    printf 'Session manager exited before startup completed.\n' >&2
    printf 'Log: %s\n' "$LOG_FILE" >&2
    exit 1
  fi

  if python3 - "$PROBE_HOST" "$PORT" >/dev/null 2>&1 <<'PY'
import socket
import sys

host = sys.argv[1]
port = int(sys.argv[2])
with socket.create_connection((host, port), timeout=0.2):
    pass
PY
  then
    break
  fi

  sleep 0.1
done

if ! python3 - "$PROBE_HOST" "$PORT" >/dev/null 2>&1 <<'PY'
import socket
import sys

host = sys.argv[1]
port = int(sys.argv[2])
with socket.create_connection((host, port), timeout=0.2):
    pass
PY
then
  kill "$server_pid" 2>/dev/null || true
  rm -f "$PID_FILE"
  printf 'Session manager did not become reachable at http://%s:%s\n' "$HOST" "$PORT" >&2
  printf 'Log: %s\n' "$LOG_FILE" >&2
  exit 1
fi

printf 'Started Claude session manager at http://%s:%s\n' "$HOST" "$PORT"
printf 'PID: %s\n' "$server_pid"
printf 'Log: %s\n' "$LOG_FILE"
