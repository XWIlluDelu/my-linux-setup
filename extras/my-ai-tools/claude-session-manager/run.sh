#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/claude-session-manager"
PID_FILE="$STATE_DIR/server.pid"
LOG_FILE="$STATE_DIR/server.log"
HOST="${SESSION_MANAGER_HOST:-127.0.0.1}"
PORT="${SESSION_MANAGER_PORT:-8765}"
PROBE_HOST="$HOST"
SCRIPT_PATH="$ROOT_DIR/session_manager_server.py"

APPLY=0
for arg in "$@"; do
  case "$arg" in
    --check) APPLY=0 ;;
    --apply) APPLY=1 ;;
    -h|--help) printf 'Usage: run.sh [--check|--apply]\n'; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$arg" >&2; exit 1 ;;
  esac
done
[[ "$HOST" == 127.0.0.1 || "$HOST" == localhost ]] || { printf 'Only loopback hosts are supported.\n' >&2; exit 1; }
[[ "$PORT" =~ ^[0-9]{1,5}$ ]] && ((10#$PORT > 0 && 10#$PORT < 65536)) || { printf 'Invalid port.\n' >&2; exit 1; }
if [[ "$APPLY" -ne 1 ]]; then
  printf '[check] Would start the deletion-capable UI at http://%s:%s; state: %s\n' "$HOST" "$PORT" "$STATE_DIR"
  exit 0
fi
umask 077
mkdir -p "$STATE_DIR"

get_listener_pid() {
  local listener_pid
  listener_pid="$(lsof -tiTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | head -n 1 || true)"
  printf '%s' "$listener_pid"
}

is_session_manager_pid() {
  local candidate_pid="$1"
  if [[ ! "$candidate_pid" =~ ^[1-9][0-9]*$ ]] || ! kill -0 "$candidate_pid" 2>/dev/null; then
    return 1
  fi

  local command
  command="$(ps -p "$candidate_pid" -o command= 2>/dev/null || true)"
  [[ "$command" == *"$SCRIPT_PATH"* ]]
}

if [[ -f "$PID_FILE" ]]; then
  existing_pid="$(cat "$PID_FILE")"
  if is_session_manager_pid "$existing_pid"; then
    printf 'Session manager is already running at http://%s:%s (PID %s)\n' "$HOST" "$PORT" "$existing_pid"
    exit 0
  fi
  rm -f "$PID_FILE"
fi

listener_pid="$(get_listener_pid)"
if [[ -n "$listener_pid" ]]; then
  if is_session_manager_pid "$listener_pid"; then
    printf '%s' "$listener_pid" > "$PID_FILE"
    printf 'Session manager is already running at http://%s:%s (PID %s)\n' "$HOST" "$PORT" "$listener_pid"
    exit 0
  fi

  printf 'Port %s is already in use by PID %s; refusing to start session manager.\n' "$PORT" "$listener_pid" >&2
  exit 1
fi

nohup python3 "$ROOT_DIR/session_manager_server.py" --serve > "$LOG_FILE" 2>&1 < /dev/null &
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

if ! kill -0 "$server_pid" 2>/dev/null; then
  rm -f "$PID_FILE"
  printf 'Session manager exited before startup completed.\n' >&2
  printf 'Log: %s\n' "$LOG_FILE" >&2
  exit 1
fi

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
