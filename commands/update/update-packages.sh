#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
source "$ROOT_DIR/lib/common.sh"

APPLY=0

usage() {
  cat <<'EOF'
Update distro packages through the system package manager.

Usage:
  update-packages.sh [--check] [--apply]

Steps:
  1. Run the reusable system package upgrade task

Notes:
  - Default mode is --check.
  - This is the normal distro package upgrade step.
  - For the full routine pass, use update-all.sh.
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
  1. $ROOT_DIR/tasks/system/upgrade-system.sh --apply

Run with --apply to execute.
EOF
  exit 0
fi

info "[1/1] Update distro packages through the system package manager"
bash "$ROOT_DIR/tasks/system/upgrade-system.sh" --apply

info "Package update completed."
