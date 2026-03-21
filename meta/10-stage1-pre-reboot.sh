#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
source "$ROOT_DIR/lib/common.sh"

ASSUME_YES=0
RUN_MODE="check"

usage() {
  cat <<'EOF'
Stage 1:
  - convert the root btrfs layout to @rootfs and @home
  - create a safety snapshot during the conversion
  - reboot automatically

Usage:
  10-stage1-pre-reboot.sh [--apply] [--yes] [-h|--help]

Options:
  --apply  Run stage 1 (prompts for confirmation unless --yes is given)
  --yes    Skip confirmation and execute immediately
  --check  Preview the underlying command without executing it (default)
EOF
}

confirm_with_text() {
  local answer
  while true; do
    printf '%s' "Stage 1 will split the Btrfs root layout into @rootfs and @home, create a safety snapshot, and reboot automatically. Continue? [y/N]: "
    read -r answer
    case "$answer" in
      y|Y|yes|YES)
        return 0
        ;;
      n|N|no|NO|'')
        return 1
        ;;
      *)
        printf 'Please answer y or n.\n' >&2
        ;;
    esac
  done
}

confirm_stage1() {
  if supports_whiptail_ui; then
    whiptail \
      --title "Linux Setup Stage 1" \
      --yesno "This will:\n\n- split the Btrfs root layout into @rootfs and @home\n- create a safety snapshot during the conversion\n- reboot automatically\n\nContinue?" \
      15 78
    return
  fi

  confirm_with_text
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes)
      ASSUME_YES=1
      RUN_MODE="apply"
      ;;
    --check)
      RUN_MODE="check"
      ;;
    --apply)
      RUN_MODE="apply"
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

if [[ "$RUN_MODE" != "apply" ]]; then
  cat <<EOF
This was a check run. The meta script would execute:

  1. $ROOT_DIR/steps/10-btrfs-layout.sh --apply --reboot

Run with --apply to execute.
EOF
  exit 0
fi

if [[ "$ASSUME_YES" -ne 1 ]]; then
  if ! has_interactive_tty; then
    die "Stage 1 needs confirmation from an interactive terminal. Re-run in a terminal, or use --yes."
  fi

  if ! confirm_stage1; then
    info "Stage 1 cancelled."
    exit 1
  fi
fi

info "[1/1] Convert root layout and reboot"
bash "$ROOT_DIR/steps/10-btrfs-layout.sh" --apply --reboot
