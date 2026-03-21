#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

usage() {
  cat <<'EOF'
Routine system maintenance.

Usage:
  system-maintain.sh [--check] [--apply]

Steps:
  1. Preseed GRUB install targets when possible on apt systems
  2. Refresh package metadata
  3. Non-interactive full system upgrade
  4. Remove unused packages
  5. Clean local package cache
  6. Purge residual config packages when supported
  7. Remove unused Flatpak data when available
  8. Check whether a reboot is required when the system exposes a known hint

Notes:
  - Default mode is --check.
  - Supports apt, dnf, zypper, and pacman.
  - This is for routine maintenance. For fixing broken packages, use repair-system.sh.
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
  4. Remove unused packages via $(package_manager_label "$PKG_MANAGER")
  5. Clean local package cache via $(package_manager_label "$PKG_MANAGER")
  6. Purge residual config packages when supported
  7. Remove unused Flatpak data when available
  8. Check whether a reboot is required when the system exposes a known hint

Run with --apply to execute.
EOF
  exit 0
fi

ensure_sudo_session

if [[ "$PKG_MANAGER" == "apt-get" ]]; then
  info "[1/8] Preseed GRUB install targets when possible"
  preseed_grub_if_possible
else
  info "[1/8] Skip GRUB preseed on $(package_manager_label "$PKG_MANAGER")"
fi

info "[2/8] Refresh package metadata via $(package_manager_label "$PKG_MANAGER")"
refresh_package_metadata

info "[3/8] Full upgrade"
full_system_upgrade

info "[4/8] Remove unused packages"
remove_unused_packages

info "[5/8] Clean local package cache"
clean_package_caches

info "[6/8] Purge residual config packages"
purge_residual_config_packages

info "[7/8] Remove unused Flatpak data when available"
if command_exists flatpak; then
  flatpak uninstall --unused -y || warn "Flatpak cleanup failed; continuing."
else
  info "flatpak not found; skipped."
fi

info "[8/8] Check reboot flag"
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

info "System maintenance completed."
