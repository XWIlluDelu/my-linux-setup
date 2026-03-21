#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

usage() {
  cat <<'EOF'
Convert a flat btrfs root layout into @rootfs and @home subvolumes.

Usage:
  10-btrfs-layout.sh [--check] [--apply] [--reboot]

Notes:
  - Default mode is --check (dry-run).
  - This script only supports a single btrfs root and a non-separate /home.
  - Use this immediately after installation, before the system diverges too much.
  - The resulting layout keeps /home on a fixed @home subvolume and prepares the
    root subvolume for snapper rollback-driven boot switching.
EOF
}

REBOOT=0
ROOT_SUBVOL="@rootfs"
HOME_SUBVOL="@home"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)
      APPLY=0
      ;;
    --apply)
      APPLY=1
      ;;
    --reboot)
      REBOOT=1
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

ROOT_SRC="$(current_root_source)"
ROOT_SUBVOL_PATH="$(current_root_subvol_path)"
ROOT_DEV="$(current_root_device)"
ROOT_UUID="$(current_root_uuid)"
ROOT_OPTS="$(normalized_btrfs_opts /)"
ROOT_FSTYPE="$(findmnt -nro FSTYPE /)"
HOME_SRC="$(findmnt -nro SOURCE /home 2>/dev/null || true)"
STAMP="$(date +%Y%m%d-%H%M%S)"
SAFETY_SNAPSHOT="@old-before-layout-$STAMP"

[[ "$ROOT_FSTYPE" == "btrfs" ]] || die "Root filesystem is '$ROOT_FSTYPE', not btrfs."
[[ -n "$ROOT_UUID" ]] || die "Unable to determine UUID of the root filesystem."

if [[ -n "$HOME_SRC" && "$HOME_SRC" != "$ROOT_SRC" ]]; then
  die "/home is mounted from a separate source: $HOME_SRC"
fi

info "Root source: $ROOT_SRC"
info "Root device: $ROOT_DEV"
info "Root UUID:   $ROOT_UUID"
info "Root opts:   $ROOT_OPTS"
info "Root subvol: ${ROOT_SUBVOL_PATH:-<top-level>}"
info "Safety snapshot name: $SAFETY_SNAPSHOT"

MODE=""
case "$ROOT_SUBVOL_PATH" in
  '')
    MODE="flat-root-to-rootfs-home"
    ;;
  "$ROOT_SUBVOL")
    MODE="split-home-from-existing-rootfs"
    ;;
  *)
    die "Unsupported root subvolume layout: '${ROOT_SUBVOL_PATH}'. Expected top-level root or ${ROOT_SUBVOL}."
    ;;
esac

if [[ "$APPLY" -ne 1 ]]; then
  if [[ "$MODE" == "split-home-from-existing-rootfs" ]]; then
    cat <<EOF

This was a check run. The script would:
  1. Install missing tools: btrfs-progs, rsync
  2. Mount the btrfs top-level subvolume
  3. Create a read-only safety snapshot of ${ROOT_SUBVOL}: $SAFETY_SNAPSHOT
  4. Create subvolume: $HOME_SUBVOL
  5. Rsync /home into $HOME_SUBVOL
  6. Rewrite /etc/fstab so / follows the default btrfs subvolume and /home stays on $HOME_SUBVOL
  7. Set $ROOT_SUBVOL as the default btrfs subvolume
  8. Disable GRUB's automatic rootflags=subvol=... injection for btrfs roots
  9. Set GRUB_DEFAULT=saved for rollback-controlled boot entry switching
 10. Rebuild initramfs and grub if matching tools are available

Run with --apply to execute.
EOF
  else
    cat <<EOF

This was a check run. The script would:
  1. Install missing tools: btrfs-progs, rsync
  2. Mount the btrfs top-level subvolume
  3. Create a read-only safety snapshot: $SAFETY_SNAPSHOT
  4. Create subvolumes: $ROOT_SUBVOL and $HOME_SUBVOL
  5. Rsync / into $ROOT_SUBVOL and /home into $HOME_SUBVOL
  6. Rewrite /etc/fstab so / follows the default btrfs subvolume and /home stays on $HOME_SUBVOL
  7. Set $ROOT_SUBVOL as the default btrfs subvolume
  8. Disable GRUB's automatic rootflags=subvol=... injection for btrfs roots
  9. Set GRUB_DEFAULT=saved for rollback-controlled boot entry switching
 10. Rebuild initramfs and grub if matching tools are available

Run with --apply to execute.
EOF
  fi
  exit 0
fi

ensure_sudo_session
install_packages btrfs-progs rsync
ensure_command btrfs
ensure_command rsync

WORKDIR="$(mktemp -d "/tmp/snapper-layout.XXXXXX")"
TOP_MNT="$WORKDIR/top"
NEWROOT_MNT="$WORKDIR/newroot"
NEWHOME_MNT="$WORKDIR/newhome"
SAFETY_MNT="$WORKDIR/safety"
mkdir -p "$TOP_MNT" "$NEWROOT_MNT" "$NEWHOME_MNT" "$SAFETY_MNT"

cleanup() {
  if mountpoint -q "$SAFETY_MNT" 2>/dev/null; then
    as_root umount "$SAFETY_MNT" || true
  fi
  if mountpoint -q "$NEWHOME_MNT" 2>/dev/null; then
    as_root umount "$NEWHOME_MNT" || true
  fi
  if mountpoint -q "$NEWROOT_MNT" 2>/dev/null; then
    as_root umount "$NEWROOT_MNT" || true
  fi
  if mountpoint -q "$TOP_MNT" 2>/dev/null; then
    as_root umount "$TOP_MNT" || true
  fi
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

run_as_root mount -o subvolid=5 "$ROOT_DEV" "$TOP_MNT"

if [[ "$MODE" == "split-home-from-existing-rootfs" ]]; then
  [[ -d "$TOP_MNT/$ROOT_SUBVOL" ]] || die "Expected $ROOT_SUBVOL to exist in the btrfs top-level."
  [[ ! -e "$TOP_MNT/$HOME_SUBVOL" ]] || die "Detected existing $HOME_SUBVOL in the btrfs top-level. Refusing to continue."

  run_as_root btrfs subvolume snapshot -r "$TOP_MNT/$ROOT_SUBVOL" "$TOP_MNT/$SAFETY_SNAPSHOT"
  run_as_root btrfs subvolume create "$TOP_MNT/$HOME_SUBVOL"
  run_as_root mount -o "$(with_subvol_opt "$ROOT_OPTS" "$HOME_SUBVOL")" "$ROOT_DEV" "$NEWHOME_MNT"

  if [[ -d /home ]]; then
    run_as_root rsync -aAXH --numeric-ids /home/ "$NEWHOME_MNT/"
  fi
else
  if [[ -e "$TOP_MNT/$ROOT_SUBVOL" || -e "$TOP_MNT/$HOME_SUBVOL" ]]; then
    die "Detected existing $ROOT_SUBVOL or $HOME_SUBVOL in the btrfs top-level. Refusing to continue."
  fi

  # The top-level btrfs subvolume (subvolid=5) cannot be snapshotted directly.
  # For flat roots, keep an equivalent safety backup by rsyncing into a dedicated
  # subvolume before layout conversion.
  run_as_root btrfs subvolume create "$TOP_MNT/$SAFETY_SNAPSHOT"
  run_as_root mount -o "$(with_subvol_opt "$ROOT_OPTS" "$SAFETY_SNAPSHOT")" "$ROOT_DEV" "$SAFETY_MNT"
  run_as_root rsync -aAXH --numeric-ids \
    --exclude='/dev/*' \
    --exclude='/proc/*' \
    --exclude='/sys/*' \
    --exclude='/run/*' \
    --exclude='/tmp/*' \
    --exclude='/mnt/*' \
    --exclude='/media/*' \
    --exclude='/lost+found' \
    --exclude='/.snapshots/*' \
    / "$SAFETY_MNT/"
  run_as_root umount "$SAFETY_MNT"
  run_as_root btrfs subvolume create "$TOP_MNT/$ROOT_SUBVOL"
  run_as_root btrfs subvolume create "$TOP_MNT/$HOME_SUBVOL"

  run_as_root mount -o "$(with_subvol_opt "$ROOT_OPTS" "$ROOT_SUBVOL")" "$ROOT_DEV" "$NEWROOT_MNT"
  run_as_root mount -o "$(with_subvol_opt "$ROOT_OPTS" "$HOME_SUBVOL")" "$ROOT_DEV" "$NEWHOME_MNT"

  run_as_root rsync -aAXH --numeric-ids \
    --exclude='/dev/*' \
    --exclude='/proc/*' \
    --exclude='/sys/*' \
    --exclude='/run/*' \
    --exclude='/tmp/*' \
    --exclude='/mnt/*' \
    --exclude='/media/*' \
    --exclude='/home/*' \
    --exclude='/lost+found' \
    --exclude='/.snapshots/*' \
    --exclude="/$ROOT_SUBVOL" \
    --exclude="/$ROOT_SUBVOL/*" \
    --exclude="/$HOME_SUBVOL" \
    --exclude="/$HOME_SUBVOL/*" \
    --exclude="/$SAFETY_SNAPSHOT" \
    --exclude="/$SAFETY_SNAPSHOT/*" \
    / "$NEWROOT_MNT/"

  run_as_root mkdir -p "$NEWROOT_MNT/home"

  if [[ -d /home ]]; then
    run_as_root rsync -aAXH --numeric-ids /home/ "$NEWHOME_MNT/"
  fi
fi

FSTAB_TMP="$(mktemp "/tmp/fstab.snapper-layout.XXXXXX")"
awk '!( $2=="/" || $2=="/home" )' /etc/fstab > "$FSTAB_TMP"
{
  printf '\n# snapper layout (%s)\n' "$STAMP"
  printf 'UUID=%s  /      btrfs  %s  0  0\n' "$ROOT_UUID" "$ROOT_OPTS"
  printf 'UUID=%s  /home  btrfs  %s  0  0\n' "$ROOT_UUID" "$(with_subvol_opt "$ROOT_OPTS" "$HOME_SUBVOL")"
} >> "$FSTAB_TMP"

run_as_root cp -a /etc/fstab "/etc/fstab.bak.$STAMP"
run_as_root cp "$FSTAB_TMP" /etc/fstab
if [[ "$MODE" == "flat-root-to-rootfs-home" ]]; then
  run_as_root cp "$FSTAB_TMP" "$NEWROOT_MNT/etc/fstab"
fi
rm -f "$FSTAB_TMP"

DEFAULT_SUBVOL_ID="$(
  as_root btrfs subvolume show "$TOP_MNT/$ROOT_SUBVOL" \
    | awk '/Subvolume ID:/ {print $3; exit}'
)"
[[ -n "$DEFAULT_SUBVOL_ID" ]] || die "Unable to determine subvolume ID for $ROOT_SUBVOL"

run_as_root btrfs subvolume set-default "$DEFAULT_SUBVOL_ID" "$TOP_MNT"
disable_grub_btrfs_rootflags_if_possible
ensure_grub_saved_default_if_possible
if [[ "$MODE" == "flat-root-to-rootfs-home" ]]; then
  run_as_root cp /etc/default/grub "$NEWROOT_MNT/etc/default/grub"
  run_as_root cp /etc/grub.d/10_linux "$NEWROOT_MNT/etc/grub.d/10_linux"
  if [[ -f /etc/grub.d/20_linux_xen ]]; then
    run_as_root cp /etc/grub.d/20_linux_xen "$NEWROOT_MNT/etc/grub.d/20_linux_xen"
  fi
fi
rebuild_initramfs_if_possible
rebuild_grub_if_possible

info "Layout conversion finished."
info "Please manually verify: findmnt /, findmnt /home, btrfs subvolume list /, /etc/fstab"

if [[ "$REBOOT" -eq 1 ]]; then
  run_as_root reboot
else
  info "Reboot was not triggered automatically. Reboot manually after verification."
fi
