#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

usage() {
  cat <<'EOF'
Install and initialize snapper for the root subvolume.

Usage:
  20-snapper-fresh.sh [--check] [--apply] [--config root] [--subvolume /] [--baseline-desc TEXT]

Notes:
  - Default mode is --check (dry-run).
  - The script enables common snapper timers if they exist.
EOF
}

ensure_snapshots_mount() {
  local root_uuid root_opts snapshots_subvol fstab_tmp current_source desired_source root_dev
  root_uuid="$(current_root_uuid)"
  root_opts="$(normalized_btrfs_opts /)"
  snapshots_subvol="$(stable_snapshots_subvol_path)"
  root_dev="$(current_root_device)"
  desired_source="${root_dev}[/${snapshots_subvol}]"

  run_as_root mkdir -p /.snapshots

  fstab_tmp="$(mktemp "/tmp/fstab.snapper-snapshots.XXXXXX")"
  awk '($2!="/.snapshots")' /etc/fstab > "$fstab_tmp"
  printf '\n# linux-setup snapper snapshots mount\n' >> "$fstab_tmp"
  printf 'UUID=%s  /.snapshots  btrfs  %s  0  0\n' "$root_uuid" "$(with_subvol_opt "$root_opts" "$snapshots_subvol")" >> "$fstab_tmp"
  run_as_root cp -a /etc/fstab /etc/fstab.bak.snapper-snapshots
  run_as_root cp "$fstab_tmp" /etc/fstab
  rm -f "$fstab_tmp"

  current_source="$(findmnt -nro SOURCE /.snapshots 2>/dev/null || true)"
  if [[ "$current_source" != "$desired_source" ]]; then
    if mountpoint -q /.snapshots 2>/dev/null; then
      try_run_as_root umount /.snapshots
    fi
    run_as_root mount -o "$(with_subvol_opt "$root_opts" "$snapshots_subvol")" "$root_dev" /.snapshots
  fi

  info "snapper snapshots are mounted from subvolume: ${snapshots_subvol}"
}

CONFIG_NAME="root"
SUBVOLUME="/"
BASELINE_DESC=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)
      APPLY=0
      ;;
    --apply)
      APPLY=1
      ;;
    --config)
      [[ $# -ge 2 ]] || die "--config requires a value"
      CONFIG_NAME="$2"
      shift
      ;;
    --subvolume)
      [[ $# -ge 2 ]] || die "--subvolume requires a value"
      SUBVOLUME="$2"
      shift
      ;;
    --baseline-desc)
      [[ $# -ge 2 ]] || die "--baseline-desc requires a value"
      BASELINE_DESC="$2"
      shift
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

require_btrfs_root

info "Config name: $CONFIG_NAME"
info "Target subvolume: $SUBVOLUME"

if [[ "$APPLY" -ne 1 ]]; then
  cat <<EOF

This was a check run. The script would:
  1. Install missing tools: btrfs-progs, snapper
  2. Create snapper config '$CONFIG_NAME' for '$SUBVOLUME' if it does not exist
  3. Auto-scale snapshot retention limits based on root partition size
  4. Mount a stable /.snapshots subvolume for post-rollback visibility
  5. Enable common snapper timers when available
EOF

  if [[ -n "$BASELINE_DESC" ]]; then
    printf '  6. Create a baseline snapshot: %s\n' "$BASELINE_DESC"
  fi

  printf '\nRun with --apply to execute.\n'
  exit 0
fi

# Auto-scale snapshot limits based on root partition size
compute_snapshot_limits() {
  local root_size_gb
  root_size_gb=$(df -BG --output=size "$SUBVOLUME" | tail -1 | tr -d ' G')

  if [[ "$root_size_gb" -lt 100 ]]; then
    NUM_LIMIT=5
    NUM_LIMIT_IMPORTANT=2
  elif [[ "$root_size_gb" -lt 500 ]]; then
    NUM_LIMIT=15
    NUM_LIMIT_IMPORTANT=5
  else
    NUM_LIMIT=30
    NUM_LIMIT_IMPORTANT=10
  fi
}

ensure_sudo_session
install_packages btrfs-progs snapper
ensure_command snapper

if [[ ! -f "/etc/snapper/configs/$CONFIG_NAME" ]]; then
  run_as_root snapper -c "$CONFIG_NAME" create-config "$SUBVOLUME"
  
  # Auto-scale cleanup limits based on disk size
  compute_snapshot_limits
  info "Root partition size detected; setting NUMBER_LIMIT=$NUM_LIMIT, NUMBER_LIMIT_IMPORTANT=$NUM_LIMIT_IMPORTANT"
  run_as_root sed -i "s/^NUMBER_LIMIT=.*\$/NUMBER_LIMIT=\"$NUM_LIMIT\"/" "/etc/snapper/configs/$CONFIG_NAME"
  run_as_root sed -i "s/^NUMBER_LIMIT_IMPORTANT=.*\$/NUMBER_LIMIT_IMPORTANT=\"$NUM_LIMIT_IMPORTANT\"/" "/etc/snapper/configs/$CONFIG_NAME"
else
  info "Snapper config already exists: /etc/snapper/configs/$CONFIG_NAME"
fi

ensure_snapshots_mount

enable_unit_if_exists snapper-cleanup.timer
enable_unit_if_exists snapper-timeline.timer
enable_unit_if_exists snapper-boot.timer

if [[ -n "$BASELINE_DESC" ]]; then
  run_as_root snapper -c "$CONFIG_NAME" create \
    --type single \
    --read-only \
    --description "$BASELINE_DESC" \
    --cleanup-algorithm number
fi

info "Configured values:"
if [[ -f "/etc/snapper/configs/$CONFIG_NAME" ]]; then
  as_root grep -E '^(SUBVOLUME|FSTYPE|NUMBER_|TIMELINE_|EMPTY_PRE_POST_)' "/etc/snapper/configs/$CONFIG_NAME" || true
fi

info "Available configurations:"
as_root snapper list-configs || true

info "Recent snapshots:"
as_root snapper -c "$CONFIG_NAME" list | tail -n 20 || true
