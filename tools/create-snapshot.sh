#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

usage() {
  cat <<'EOF'
Create a read-only snapper snapshot.

Usage:
  create-snapshot.sh [--check] [--apply] [--description TEXT] [--config root] [--cleanup number]

Notes:
  - Default mode is --check.
  - In apply mode, the script prompts for a description when interactive input is available and --description is omitted.
EOF
}

CONFIG_NAME="root"
CLEANUP_ALGO="number"
DESCRIPTION=""

prompt_snapshot_description_text() {
  while true; do
    printf '%s' "Snapshot description: " >&2
    read -r DESCRIPTION
    DESCRIPTION="${DESCRIPTION#"${DESCRIPTION%%[![:space:]]*}"}"
    DESCRIPTION="${DESCRIPTION%"${DESCRIPTION##*[![:space:]]}"}"
    if [[ -n "$DESCRIPTION" ]]; then
      return 0
    fi
    printf 'Snapshot description cannot be empty.\n' >&2
  done
}

prompt_snapshot_description_whiptail() {
  while true; do
    DESCRIPTION="$(
      whiptail \
        --title "Create Snapshot" \
        --inputbox "Snapshot description:" \
        12 72 \
        "${DESCRIPTION:-}" \
        3>&1 1>&2 2>&3
    )" || die "Snapshot creation cancelled."

    DESCRIPTION="${DESCRIPTION#"${DESCRIPTION%%[![:space:]]*}"}"
    DESCRIPTION="${DESCRIPTION%"${DESCRIPTION##*[![:space:]]}"}"
    if [[ -n "$DESCRIPTION" ]]; then
      return 0
    fi
    warn "Snapshot description cannot be empty."
  done
}

collect_snapshot_description() {
  if [[ -n "$DESCRIPTION" ]]; then
    return 0
  fi

  if supports_whiptail_ui; then
    prompt_snapshot_description_whiptail
    return 0
  fi

  if has_interactive_input_tty; then
    prompt_snapshot_description_text
    return 0
  fi

  die "description is required in non-interactive mode; pass --description TEXT"
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
    --cleanup)
      [[ $# -ge 2 ]] || die "--cleanup requires a value"
      CLEANUP_ALGO="$2"
      shift
      ;;
    --description)
      [[ $# -ge 2 ]] || die "--description requires a value"
      DESCRIPTION="$2"
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

if [[ "$APPLY" -ne 1 ]]; then
  cat <<EOF
This was a check run. The script would:
  1. Show existing snapshots for config '$CONFIG_NAME'
  2. Create a new read-only snapshot with cleanup algorithm '$CLEANUP_ALGO'
EOF
  if [[ -n "$DESCRIPTION" ]]; then
    printf '  3. Use description: %s\n' "$DESCRIPTION"
  else
    info "  3. Prompt for a description interactively, or use --description TEXT"
  fi
  printf '\nRun with --apply to execute.\n'
  exit 0
fi

ensure_sudo_session

info "[1/3] Show existing snapshots"
as_root snapper -c "$CONFIG_NAME" list

info "[2/3] Create a new snapshot (describe what you just configured)"
collect_snapshot_description

as_root snapper -c "$CONFIG_NAME" create \
  --type single \
  --read-only \
  --description "$DESCRIPTION" \
  --cleanup-algorithm "$CLEANUP_ALGO"

info "[3/3] Show snapshots (latest at bottom)"
as_root snapper -c "$CONFIG_NAME" list | tail -n 20
