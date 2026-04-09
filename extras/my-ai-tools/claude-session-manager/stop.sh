#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_FILE="$ROOT_DIR/session-manager.pid"

if [[ ! -f "$PID_FILE" ]]; then
  printf 'No PID file found. Session manager may already be stopped.\n'
  exit 0
fi

pid="$(cat "$PID_FILE")"
rm -f "$PID_FILE"

if [[ -z "$pid" ]]; then
  printf 'PID file was empty. Nothing to stop.\n'
  exit 0
fi

if kill -0 "$pid" 2>/dev/null; then
  kill "$pid"
  printf 'Stopped Claude session manager (PID %s).\n' "$pid"
else
  printf 'Process %s is not running.\n' "$pid"
fi
