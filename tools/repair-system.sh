#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

usage() {
  cat <<'EOF'
Repair package state and rebuild kernel-related artifacts on Debian/Ubuntu.

Usage:
  repair-system.sh [--check] [--apply]

Notes:
  - Default mode is --check.
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

ensure_command sudo
ensure_command apt-get
ensure_command dpkg

if [[ "$APPLY" -ne 1 ]]; then
  cat <<'EOF'
This was a check run. The script would:
  1. Refresh package metadata
  2. Finish half-configured packages
  3. Fix broken package dependencies
  4. Rebuild DKMS modules when dkms is installed
  5. Rebuild initramfs and grub artifacts when matching tools are available

Run with --apply to execute.
EOF
  exit 0
fi

ensure_sudo_session

info "[1/5] Refresh package metadata"
run_as_root apt-get update

info "[2/5] Finish half-configured packages"
run_as_root dpkg --configure -a

info "[3/5] Fix package dependencies"
run_as_root apt-get install -f -y

info "[4/5] Rebuild DKMS modules"
if command_exists dkms; then
  run_as_root dkms autoinstall
else
  warn "dkms not found; skipped."
fi

info "[5/5] Rebuild boot artifacts when available"
rebuild_initramfs_if_possible
rebuild_grub_if_possible

warn "If this repair was triggered by a driver or kernel issue, reboot manually after reviewing the output."
