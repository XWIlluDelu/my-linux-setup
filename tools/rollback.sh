#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

usage() {
  cat <<'EOF'
Create a boot-level rollback target with snapper rollback.

Usage:
  rollback.sh [--check] [--apply] [--snapshot N] [--config root] [--no-reboot]

Notes:
  - Default mode is --check.
  - This uses "snapper --no-dbus --ambit classic rollback".
  - Reboot is required to enter the restored root. In apply mode, reboot is
    triggered automatically unless --no-reboot is provided.
  - /home is intentionally not rolled back when it lives on a separate
    subvolume such as @home.
  - In apply mode, the script can prompt for the snapshot number when an
    interactive terminal is available and --snapshot is omitted.
EOF
}

CONFIG_NAME="root"
SNAPSHOT=""
AUTO_REBOOT=1
SNAPSHOT_EXPLICIT=0
AUTO_REBOOT_EXPLICIT=0
ROLLBACK_ENTRY_ID=""
ROLLBACK_ENTRY_TITLE=""
ROLLBACK_CUSTOM_CFG_CONTENT=""
ROLLBACK_BOOT_DIR=""
ROLLBACK_NEW_SNAPSHOT=""
ROLLBACK_TARGET_SUBVOL=""
ROLLBACK_KERNEL_PATH=""
ROLLBACK_INITRD_PATH=""
SNAPSHOT_ROWS=""

cleanup() {
  if [[ -n "${TOP_MNT:-}" ]] && mountpoint -q "$TOP_MNT" 2>/dev/null; then
    as_root umount "$TOP_MNT" || true
  fi

  [[ -n "${WORKDIR:-}" ]] && rm -rf "$WORKDIR"
  return 0
}
trap cleanup EXIT

current_root_mount() {
  findmnt -no SOURCE,OPTIONS / 2>/dev/null || true
}

trim_space() {
  local value
  value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s\n' "$value"
}

list_snapshots_for_display() {
  if [[ "$APPLY" -eq 1 ]]; then
    as_root snapper -c "$CONFIG_NAME" list || true
    return 0
  fi

  if snapper -c "$CONFIG_NAME" list >/dev/null 2>&1; then
    snapper -c "$CONFIG_NAME" list || true
  else
    info "Snapshot listing requires privileges on this system."
    info "Run manually: sudo snapper -c $CONFIG_NAME list"
  fi
}

load_snapshot_rows() {
  SNAPSHOT_ROWS="$(
    as_root snapper --iso --csvout --separator $'\t' --no-headers -c "$CONFIG_NAME" list \
      --columns number,type,date,cleanup,description 2>/dev/null \
      | awk 'NF' \
      | sort -t $'\t' -k1,1nr
  )"
}

snapshot_exists_in_rows() {
  local target
  target="$1"

  awk -F'\t' -v target="$target" '
    {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1)
      if ($1 == target) {
        found = 1
      }
    }
    END {
      exit found ? 0 : 1
    }
  ' <<<"$SNAPSHOT_ROWS"
}

snapshot_summary_from_rows() {
  local target
  target="$1"

  awk -F'\t' -v target="$target" '
    function trim(v) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      return v
    }
    {
      number = trim($1)
      if (number == target) {
        type = trim($2)
        date = trim($3)
        cleanup = trim($4)
        description = trim($5)
        if (cleanup == "") cleanup = "-"
        if (description == "") description = "(no description)"
        printf("#%s | %s | %s | %s", number, type, date, description)
        exit 0
      }
    }
  ' <<<"$SNAPSHOT_ROWS"
}

collect_snapshot_with_text() {
  local answer

  info "Available snapshots:"
  list_snapshots_for_display

  while true; do
    printf '%s' "Rollback snapshot number: " >&2
    read -r answer
    answer="$(trim_space "$answer")"

    if [[ ! "$answer" =~ ^[0-9]+$ ]]; then
      printf 'Please enter a numeric snapshot id.\n' >&2
      continue
    fi

    if snapshot_exists_in_rows "$answer"; then
      SNAPSHOT="$answer"
      return 0
    fi

    printf 'Snapshot %s was not found.\n' "$answer" >&2
  done
}

collect_snapshot_with_whiptail() {
  local number type date cleanup description summary
  local -a options=()

  while IFS=$'\t' read -r number type date cleanup description; do
    [[ -n "${number:-}" ]] || continue
    number="$(trim_space "$number")"
    type="$(trim_space "$type")"
    date="$(trim_space "$date")"
    cleanup="$(trim_space "$cleanup")"
    description="$(trim_space "$description")"
    [[ -n "$cleanup" ]] || cleanup="-"
    [[ -n "$description" ]] || description="(no description)"
    if [[ "${#description}" -gt 56 ]]; then
      description="${description:0:53}..."
    fi
    summary="${type} | ${date} | ${description}"
    options+=("$number" "$summary")
  done <<<"$SNAPSHOT_ROWS"

  [[ "${#options[@]}" -gt 0 ]] || die "No snapshots are available for config '$CONFIG_NAME'."

  SNAPSHOT="$(
    whiptail \
      --title "Rollback Snapshot" \
      --menu "Choose a snapshot to roll back to." \
      22 110 12 \
      "${options[@]}" \
      3>&1 1>&2 2>&3
  )" || die "Rollback cancelled."
}

collect_snapshot_interactively() {
  if [[ -n "$SNAPSHOT" ]]; then
    return 0
  fi

  if ! has_interactive_input_tty; then
    die "Please choose a snapshot with --snapshot N"
  fi

  load_snapshot_rows
  [[ -n "$SNAPSHOT_ROWS" ]] || die "No snapshots are available for config '$CONFIG_NAME'."

  if supports_whiptail_ui; then
    collect_snapshot_with_whiptail
  else
    collect_snapshot_with_text
  fi
}

collect_auto_reboot_choice() {
  local reboot_now

  if [[ "$AUTO_REBOOT_EXPLICIT" -eq 1 ]]; then
    return 0
  fi

  if ! has_interactive_input_tty; then
    return 0
  fi

  if supports_whiptail_ui; then
    if whiptail \
      --title "Rollback Reboot" \
      --yesno "Reboot automatically after preparing the rollback target?" \
      11 78; then
      AUTO_REBOOT=1
    else
      AUTO_REBOOT=0
    fi
    return 0
  fi

  reboot_now="$AUTO_REBOOT"
  prompt_bool_text reboot_now "Reboot automatically after preparing the rollback target?" "$reboot_now"
  AUTO_REBOOT="$reboot_now"
}

confirm_rollback_action() {
  local summary prompt confirm_choice
  summary="$(snapshot_summary_from_rows "$SNAPSHOT")"
  [[ -n "$summary" ]] || summary="#$SNAPSHOT"

  if ! has_interactive_input_tty; then
    return 0
  fi

  prompt="Create a rollback target from:\n\n${summary}\n\nThis will create a new writable rollback snapshot and prepare GRUB to boot into it.\nAutomatic reboot: $( [[ "$AUTO_REBOOT" -eq 1 ]] && printf 'yes' || printf 'no' )"

  if supports_whiptail_ui; then
    whiptail \
      --title "Confirm Rollback" \
      --yesno "$prompt" \
      15 92
    return
  fi

  confirm_choice=0
  prompt_bool_text confirm_choice "Proceed with rollback from snapshot #$SNAPSHOT?" 0
  [[ "$confirm_choice" -eq 1 ]]
}

current_kernel_args_for_rollback() {
  local token args=()

  for token in $(cat /proc/cmdline 2>/dev/null || true); do
    case "$token" in
      BOOT_IMAGE=*|root=*|rootflags=*|initrd=*|subvol=*|subvolid=*)
        ;;
      ro|rw)
        ;;
      *)
        args+=("$token")
        ;;
    esac
  done

  if [[ "${#args[@]}" -gt 0 ]]; then
    printf '%s' "${args[*]}"
  fi
}

prepare_grub_snapshot_boot_entry() {
  local stable_root_subvol snapshots_subvol root_uuid root_dev partmap kernel_source initrd_source kernel_rel initrd_rel extra_args partmap_line

  stable_root_subvol="$(stable_root_subvol_path)"
  snapshots_subvol="$(stable_snapshots_subvol_path)"
  root_uuid="$(current_root_uuid)"
  root_dev="$(current_root_device)"
  partmap="$(grub-probe --target=partmap /boot 2>/dev/null || true)"

  [[ -n "$ROLLBACK_NEW_SNAPSHOT" ]] || die "Rollback snapshot number was not captured."
  [[ -n "$root_uuid" ]] || die "Unable to determine root filesystem UUID for the rollback boot entry."

  ROLLBACK_TARGET_SUBVOL="${snapshots_subvol}/${ROLLBACK_NEW_SNAPSHOT}/snapshot"

  WORKDIR="$(mktemp -d "/tmp/linux-setup-rollback.XXXXXX")"
  TOP_MNT="$WORKDIR/top"
  mkdir -p "$TOP_MNT"
  run_as_root mount -o subvolid=5 "$root_dev" "$TOP_MNT"

  kernel_source="$(
    as_root find "$TOP_MNT/$ROLLBACK_TARGET_SUBVOL/boot" -maxdepth 1 -type f -name 'vmlinuz-*' -printf '%P\n' 2>/dev/null \
      | sort -V \
      | tail -n 1
  )"
  [[ -n "$kernel_source" ]] || die "Could not find a kernel image inside rollback snapshot ${ROLLBACK_NEW_SNAPSHOT}."

  initrd_source="initrd.img-${kernel_source#vmlinuz-}"
  [[ -f "$TOP_MNT/$ROLLBACK_TARGET_SUBVOL/boot/$initrd_source" ]] || die "Could not find matching initrd '$initrd_source' inside rollback snapshot ${ROLLBACK_NEW_SNAPSHOT}."

  kernel_rel="/${ROLLBACK_TARGET_SUBVOL}/boot/${kernel_source}"
  initrd_rel="/${ROLLBACK_TARGET_SUBVOL}/boot/${initrd_source}"
  extra_args="$(current_kernel_args_for_rollback)"

  ROLLBACK_KERNEL_PATH="$kernel_rel"
  ROLLBACK_INITRD_PATH="$initrd_rel"
  ROLLBACK_ENTRY_ID="linux-setup-rollback-${ROLLBACK_NEW_SNAPSHOT}"
  ROLLBACK_ENTRY_TITLE="Linux Setup rollback snapshot ${ROLLBACK_NEW_SNAPSHOT}"
  if [[ -n "$stable_root_subvol" ]]; then
    ROLLBACK_BOOT_DIR="$TOP_MNT/$stable_root_subvol/boot"
  else
    ROLLBACK_BOOT_DIR="$TOP_MNT/boot"
  fi

  if [[ -n "$partmap" ]]; then
    partmap_line="    insmod part_${partmap}"
  else
    partmap_line=""
  fi

  ROLLBACK_CUSTOM_CFG_CONTENT=$(
    cat <<EOF
menuentry '${ROLLBACK_ENTRY_TITLE}' --id '${ROLLBACK_ENTRY_ID}' {
${partmap_line}
    insmod btrfs
    search --no-floppy --fs-uuid --set=root ${root_uuid}
    echo 'Loading Linux ${kernel_source#vmlinuz-} ...'
    linux ${kernel_rel} root=UUID=${root_uuid} ro rootflags=subvol=${ROLLBACK_TARGET_SUBVOL}${extra_args:+ ${extra_args}}
    echo 'Loading initial ramdisk ...'
    initrd ${initrd_rel}
}
EOF
  )

  info "Rollback boot entry will use:"
  info "  entry id:    ${ROLLBACK_ENTRY_ID}"
  info "  snapshot:    ${ROLLBACK_NEW_SNAPSHOT}"
  info "  subvolume:   ${ROLLBACK_TARGET_SUBVOL}"
  info "  kernel path: ${ROLLBACK_KERNEL_PATH}"
  info "  initrd path: ${ROLLBACK_INITRD_PATH}"
}

install_grub_snapshot_boot_entry() {
  local custom_cfg
  custom_cfg="${ROLLBACK_BOOT_DIR}/grub/custom.cfg"

  run_as_root mkdir -p "$(dirname "$custom_cfg")"
  run_as_root bash -c "cat > $(printf '%q' "$custom_cfg")" <<< "# Managed by linux-setup rollback
${ROLLBACK_CUSTOM_CFG_CONTENT}
"
  info "Installed rollback GRUB entry at ${custom_cfg}"
}

retarget_grub_to_rollback_entry() {
  if command -v grub-reboot >/dev/null 2>&1; then
    run_as_root grub-reboot --boot-directory="$ROLLBACK_BOOT_DIR" "$ROLLBACK_ENTRY_ID"
    info "Configured the next boot to use rollback entry: ${ROLLBACK_ENTRY_ID}"
  else
    warn "grub-reboot is unavailable; the next boot may still follow the current default GRUB entry."
  fi

  if grep -Eq '^GRUB_DEFAULT=saved$' /etc/default/grub 2>/dev/null && command -v grub-set-default >/dev/null 2>&1; then
    run_as_root grub-set-default --boot-directory="$ROLLBACK_BOOT_DIR" "$ROLLBACK_ENTRY_ID"
    info "Configured the persistent default boot entry: ${ROLLBACK_ENTRY_ID}"
  else
    warn "Persistent GRUB default was not updated. Ensure GRUB_DEFAULT=saved is configured if you want future reboots to stay on the rollback snapshot."
  fi
}

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
    --snapshot)
      [[ $# -ge 2 ]] || die "--snapshot requires a value"
      SNAPSHOT="$2"
      SNAPSHOT_EXPLICIT=1
      shift
      ;;
    --no-reboot)
      AUTO_REBOOT=0
      AUTO_REBOOT_EXPLICIT=1
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

ensure_command snapper

if [[ -z "$SNAPSHOT" ]]; then
  info "Available snapshots:"
  list_snapshots_for_display
  if [[ "$APPLY" -ne 1 ]]; then
    cat <<EOF

This was a check run. In apply mode, the script can prompt you to choose a snapshot interactively.

Run with --apply to execute, or add --snapshot N to preview a specific rollback target.
EOF
    exit 0
  fi
fi

info "Current root mount: $(current_root_mount)"
info "Target config: $CONFIG_NAME"
if [[ -n "$SNAPSHOT" ]]; then
  info "Rollback target snapshot: $SNAPSHOT"
fi
info "Available snapshots:"
list_snapshots_for_display

if [[ "$APPLY" -ne 1 ]]; then
  cat <<EOF

This was a check run. The script would run:
  snapper --no-dbus --ambit classic -c $CONFIG_NAME rollback -p $SNAPSHOT
  write a GRUB custom entry for the newly created writable rollback snapshot
  point the next boot at that snapshot-specific entry

After rollback creation, the machine would $( [[ "$AUTO_REBOOT" -eq 1 ]] && printf 'reboot automatically' || printf 'wait for a manual reboot' ).
EOF
  exit 0
fi

ensure_sudo_session
load_snapshot_rows
collect_snapshot_interactively
collect_auto_reboot_choice
confirm_rollback_action || die "Rollback cancelled."
info "Rollback target snapshot: $SNAPSHOT"

ROLLBACK_NEW_SNAPSHOT="$(
  as_root snapper --no-dbus --ambit classic -c "$CONFIG_NAME" rollback -p "$SNAPSHOT" \
    | awk 'NF {last=$NF} END {gsub(/[^0-9]/, "", last); print last}'
)"
[[ -n "$ROLLBACK_NEW_SNAPSHOT" ]] || die "Failed to determine the writable rollback snapshot number."

prepare_grub_snapshot_boot_entry
install_grub_snapshot_boot_entry
retarget_grub_to_rollback_entry

info "Rollback target created. The restored root takes effect only after reboot."

if [[ "$AUTO_REBOOT" -eq 1 ]]; then
  run_as_root reboot
else
  info "Reboot was not triggered automatically."
fi
