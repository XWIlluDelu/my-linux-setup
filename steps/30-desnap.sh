#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

usage() {
  cat <<'EOF'
Remove snap/snapd from Debian/Ubuntu apt-get systems and write an APT pin to keep it removed.

Usage:
  30-desnap.sh [--check] [--apply]

Notes:
  - Default mode is --check (dry-run).
  - This script expects an apt-get based Debian/Ubuntu system.
  - If snap/snapd is already absent, the script only enforces the APT pin and refreshes package metadata.
EOF
}

EXT_UUID="snapd-prompting@canonical.com"
EXT_PATH="/usr/share/gnome-shell/extensions/$EXT_UUID"
NOSNAP_PREF="/etc/apt/preferences.d/nosnap.pref"

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

command -v apt-get >/dev/null 2>&1 || die "This script expects an apt-get based Debian/Ubuntu system."

detect_os_release
info "Detected distro: $DISTRO_PRETTY"
case "$DISTRO_ID" in
  ubuntu|debian)
    ;;
  *)
    warn "Unverified distro ID '$DISTRO_ID'. Continuing because APT is available."
    ;;
esac

if [[ "$APPLY" -eq 1 ]]; then
  ensure_sudo_session
fi

mapfile -t SNAP_PACKAGES < <(
  if command -v snap >/dev/null 2>&1; then
    snap list 2>/dev/null | awk 'NR > 1 {print $1}'
  fi
)

mapfile -t SNAP_MOUNTS < <(
  findmnt -rn -o TARGET 2>/dev/null | awk '$1 == "/snap" || $1 ~ "^/snap/"'
)

SNAPD_INSTALLED=0
if dpkg_package_installed snapd; then
  SNAPD_INSTALLED=1
fi

info "snap package count: ${#SNAP_PACKAGES[@]}"
info "snap mount count: ${#SNAP_MOUNTS[@]}"
info "snapd package installed: $SNAPD_INSTALLED"

if [[ ${#SNAP_PACKAGES[@]} -eq 0 && "$SNAPD_INSTALLED" -eq 0 ]]; then
  info "snap and snapd are already absent; only the APT pin will be enforced."
fi

if [[ ${#SNAP_PACKAGES[@]} -gt 0 ]]; then
  printf '%s\n' "${SNAP_PACKAGES[@]}" | sed 's/^/[INFO] installed snap: /'
fi

if [[ ${#SNAP_MOUNTS[@]} -gt 0 ]]; then
  printf '%s\n' "${SNAP_MOUNTS[@]}" | sed 's/^/[INFO] snap mount: /'
fi

if [[ -d "$EXT_PATH" ]]; then
  if command -v dpkg >/dev/null 2>&1; then
    dpkg -S "$EXT_PATH" 2>/dev/null | head -n 1 | sed 's/^/[INFO] extension owner: /' || true
  fi
  if command -v gnome-extensions >/dev/null 2>&1; then
    try_run gnome-extensions disable "$EXT_UUID"
  else
    warn "GNOME extension exists but 'gnome-extensions' is unavailable."
  fi
else
  info "GNOME extension not present: $EXT_UUID"
fi

if [[ ${#SNAP_PACKAGES[@]} -gt 0 ]]; then
  for pkg in "${SNAP_PACKAGES[@]}"; do
    try_run_as_root snap remove --purge "$pkg"
  done
else
  info "No installed snap packages detected."
fi

if command -v systemctl >/dev/null 2>&1; then
  for unit in snapd.socket snapd.service snapd.seeded.service; do
    if systemctl list-unit-files "$unit" --no-legend 2>/dev/null | grep -q "^$unit"; then
      try_run_as_root systemctl stop "$unit"
      try_run_as_root systemctl disable --now "$unit"
    else
      info "systemd unit not present: $unit"
    fi
  done
else
  warn "systemctl not found; skipping service management."
fi

if [[ ${#SNAP_MOUNTS[@]} -gt 0 ]]; then
  for mountpoint in "${SNAP_MOUNTS[@]}"; do
    try_run_as_root umount "$mountpoint" -lf
  done
else
  info "No mounted /snap entries detected."
fi

if [[ "$SNAPD_INSTALLED" -eq 1 ]]; then
  try_run_as_root apt-get purge -y snapd
else
  info "snapd package is already absent."
fi

for path in "$HOME/snap" /var/snap /var/lib/snapd /var/cache/snapd /usr/lib/snapd /snap; do
  if [[ -e "$path" ]]; then
    try_run_as_root rm -rf -- "$path"
  else
    info "Path not present: $path"
  fi
done

if [[ "$APPLY" -eq 1 ]]; then
  info "+ write $NOSNAP_PREF"
  as_root mkdir -p "$(dirname "$NOSNAP_PREF")"
  as_root tee "$NOSNAP_PREF" >/dev/null <<'EOF'
Package: snapd
Pin: release a=*
Pin-Priority: -10
EOF
else
  info "[dry-run] write $NOSNAP_PREF"
fi

try_run_as_root apt-get update

if [[ "$APPLY" -eq 1 ]]; then
  info "Snap has been purged and locked."
else
  info "Check run completed. Re-run with --apply to make changes."
fi
