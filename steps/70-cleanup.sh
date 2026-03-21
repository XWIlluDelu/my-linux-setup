#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

usage() {
  cat <<'EOF'
Run routine cleanup after installation and upgrades.

Usage:
  70-cleanup.sh [--check] [--apply]

Notes:
  - Default mode is --check.
  - Supports apt, dnf, zypper, and pacman.
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
  1. Remove unused packages via $(package_manager_label "$PKG_MANAGER")
  2. Clean package caches via $(package_manager_label "$PKG_MANAGER")
  3. Purge residual config packages when the package manager exposes that concept
  4. Remove unused Flatpak data when Flatpak is installed
  5. Check whether a reboot is required when the system exposes a known hint

Run with --apply to execute.
EOF
  exit 0
fi

ensure_sudo_session

info "[1/5] Remove unused packages"
remove_unused_packages

info "[2/5] Clean local package cache"
clean_package_caches

info "[3/5] Purge residual config packages"
purge_residual_config_packages

info "[4/5] Remove unused Flatpak data when available"
if command_exists flatpak; then
  flatpak uninstall --unused -y
else
  warn "flatpak not found; skipped."
fi

info "[5/5] Check reboot flag"
if check_reboot_requirement; then
  warn "A reboot is required."
else
  case "$?" in
    1)
      info "No reboot requirement was detected."
      ;;
    *)
      warn "Could not determine reboot status for this distro."
      ;;
  esac
fi
