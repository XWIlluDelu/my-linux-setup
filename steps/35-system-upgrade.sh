#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

usage() {
  cat <<'EOF'
Run a non-interactive system upgrade.

Usage:
  35-system-upgrade.sh [--check] [--apply]

Notes:
  - Default mode is --check.
  - Supports apt, dnf, zypper, and pacman.
  - GRUB is preseeded from existing debconf values when possible on apt-based systems.
EOF
}

PKG_MANAGER="$(detect_pkg_manager 2>/dev/null || true)"
[[ -n "$PKG_MANAGER" ]] || die "No supported package manager detected. Supported: apt, dnf, zypper, pacman."

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

if [[ "$APPLY" -ne 1 ]]; then
  cat <<EOF
This was a check run. The script would:
  1. $( [[ "$PKG_MANAGER" == "apt-get" ]] && printf 'Preseed existing GRUB install targets when possible' || printf 'Skip GRUB preseed because this is not an apt-based workflow' )
  2. Refresh package metadata via $(package_manager_label "$PKG_MANAGER")
  3. Run a non-interactive full system upgrade

Run with --apply to execute.
EOF
  exit 0
fi

ensure_sudo_session

if [[ "$PKG_MANAGER" == "apt-get" ]]; then
  info "[1/3] Preseed GRUB install targets when possible"
  preseed_grub_if_possible

  info "[2/3] Refresh package metadata via apt"
  refresh_package_metadata

  info "[3/3] Full system upgrade"
  full_system_upgrade
else
  info "[1/2] Refresh package metadata via $(package_manager_label "$PKG_MANAGER")"
  refresh_package_metadata

  info "[2/2] Full system upgrade"
  full_system_upgrade
fi
