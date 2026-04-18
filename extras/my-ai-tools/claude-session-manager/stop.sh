#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_FILE="$ROOT_DIR/session-manager.pid"
PORT="${SESSION_MANAGER_PORT:-8765}"
SCRIPT_PATH="$ROOT_DIR/session_manager_server.py"

get_listener_pid() {
  local listener_pid
  listener_pid="$(lsof -tiTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | head -n 1 || true)"
  printf '%s' "$listener_pid"
}

is_session_manager_pid() {
  local candidate_pid="$1"
  if [[ -z "$candidate_pid" ]] || ! kill -0 "$candidate_pid" 2>/dev/null; then
    return 1
  fi

  local command
  command="$(ps -p "$candidate_pid" -o command= 2>/dev/null || true)"
  [[ "$command" == *"$SCRIPT_PATH"* ]]
}

stop_pid() {
  local target_pid="$1"
  if ! is_session_manager_pid "$target_pid"; then
    return 1
  fi

  kill "$target_pid"
  printf 'Stopped Claude session manager (PID %s).\n' "$target_pid"
  return 0
}

if [[ ! -f "$PID_FILE" ]]; then
  listener_pid="$(get_listener_pid)"
  if stop_pid "$listener_pid"; then
    exit 0
  fi

  printf 'No PID file found. Session manager may already be stopped.\n'
  exit 0
fi

pid="$(cat "$PID_FILE")"
rm -f "$PID_FILE"

if [[ -z "$pid" ]]; then
  listener_pid="$(get_listener_pid)"
  if stop_pid "$listener_pid"; then
    exit 0
  fi

  printf 'PID file was empty. Nothing to stop.\n'
  exit 0
fi

if stop_pid "$pid"; then
  exit 0
fi

listener_pid="$(get_listener_pid)"
if stop_pid "$listener_pid"; then
  exit 0
fi

printf 'Process %s is not running.\n' "$pid"
