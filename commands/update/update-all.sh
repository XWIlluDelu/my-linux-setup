#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
source "$ROOT_DIR/lib/common.sh"

APPLY=0

usage() {
  cat <<'EOF'
Routine update flow.

Usage:
  update-all.sh [--check] [--apply]

Steps:
  1. Update distro packages
  2. Refresh managed apps and shell components when they are detected
  3. Run the reusable cleanup task

Notes:
  - Default mode is --check.
  - This is the main day-to-day update entrypoint.
  - For fixing broken packages, use repair-system.sh.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)
      APPLY=0
      ;;
    --apply)
      APPLY=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
  shift
done

if [[ "$APPLY" -ne 1 ]]; then
  cat <<EOF
This was a check run. The script would:
  1. $ROOT_DIR/commands/update/update-packages.sh --apply
  2. $ROOT_DIR/flows/update-apps.sh --apply --yes
  3. $ROOT_DIR/tasks/system/cleanup-system.sh --apply

Run with --apply to execute.
EOF
  exit 0
fi

info "[1/3] Update distro packages"
bash "$ROOT_DIR/commands/update/update-packages.sh" --apply

info "[2/3] Refresh managed apps and shell components when they are detected"
bash "$ROOT_DIR/flows/update-apps.sh" --apply --yes </dev/null

info "[3/3] Run the reusable cleanup task"
bash "$ROOT_DIR/tasks/system/cleanup-system.sh" --apply

info "Routine update completed."
