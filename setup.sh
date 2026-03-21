#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

has_interactive_tty() {
  [[ -t 0 && -t 1 ]]
}

supports_whiptail_ui() {
  has_interactive_tty || return 1
  command_exists whiptail || return 1
  [[ -n "${TERM:-}" && "${TERM:-}" != "dumb" ]] || return 1
  return 0
}

restore_tty_after_whiptail() {
  stty sane 2>/dev/null || true
  tput sgr0 2>/dev/null || true
  tput cnorm 2>/dev/null || true
}

usage() {
  cat <<'EOF'
Linux Setup entrypoint.

Usage:
  setup.sh
  setup.sh stage1 [meta-10-args...]
  setup.sh stage2 [meta-20-args...]
  setup.sh update [meta-30-args...]
  setup.sh nvidia [nvidia-args...]
  setup.sh check

Aliases:
  stage1:        s1
  stage2:        s2
  update:        u, extras
  nvidia:        nv

Notes:
  - Running `setup.sh` without arguments opens an interactive menu.
  - The interactive menu uses whiptail by default when available.
  - Set `LINUX_SETUP_FORCE_TEXT_UI=1` to force plain text prompts.
  - Use command mode with `--yes` only for unattended/non-interactive runs.
  - In command mode, you must pass --check or --apply explicitly.
  - In interactive mode, the terms are `preview` (= --check) and `execute` (= --apply).
EOF
}

die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

has_explicit_mode_flag() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --apply|--check)
        return 0
        ;;
    esac
  done
  return 1
}

ensure_explicit_mode_flag() {
  if ! has_explicit_mode_flag "$@"; then
    die "Please choose explicit mode: add --check or --apply."
  fi
}

confirm_yes_no_required_text() {
  local prompt answer
  prompt="$1"
  while true; do
    printf '%s [y/n]: ' "$prompt" >&2
    read -r answer
    case "$answer" in
      y|Y|yes|YES)
        return 0
        ;;
      n|N|no|NO)
        return 1
        ;;
      *)
        printf 'Please answer y or n.\n' >&2
        ;;
    esac
  done
}

pick_mode_text() {
  local answer
  while true; do
    printf 'Choose mode (preview/execute): ' >&2
    read -r answer
    case "$answer" in
      preview|Preview|PREVIEW|check|Check|CHECK)
        printf '%s\n' '--check'
        return 0
        ;;
      execute|Execute|EXECUTE|apply|Apply|APPLY)
        printf '%s\n' '--apply'
        return 0
        ;;
      *)
        printf 'Please input preview or execute.\n' >&2
        ;;
    esac
  done
}

pick_profile_text() {
  local answer
  while true; do
    printf 'Choose profile (desktop/server): ' >&2
    read -r answer
    case "$answer" in
      desktop|Desktop|DESKTOP)
        printf 'desktop\n'
        return 0
        ;;
      server|Server|SERVER)
        printf 'server\n'
        return 0
        ;;
      *)
        printf 'Please input desktop or server.\n' >&2
        ;;
    esac
  done
}

pick_action_text() {
  local answer
  cat >&2 <<'EOF'
Linux Setup actions:
  1) stage1  - btrfs layout conversion + reboot
  2) stage2  - post-reboot setup
  3) update  - update extras
  4) nvidia  - interactive NVIDIA driver + CUDA installer
  5) preview-all - dry-run preview for stage1/stage2/update
  6) quit
EOF
  while true; do
    printf 'Choose action [1-6]: ' >&2
    read -r answer
    case "$answer" in
      1) printf 'stage1\n'; return 0 ;;
      2) printf 'stage2\n'; return 0 ;;
      3) printf 'update\n'; return 0 ;;
      4) printf 'nvidia\n'; return 0 ;;
      5) printf 'preview_all\n'; return 0 ;;
      6) printf 'quit\n'; return 0 ;;
      *) printf 'Please input a number between 1 and 6.\n' >&2 ;;
    esac
  done
}

run_stage1_text() {
  local mode
  local -a cmd
  mode="$(pick_mode_text)"
  cmd=("$SCRIPT_DIR/meta/10-stage1-pre-reboot.sh" "$mode")
  printf 'Running: %q' "${cmd[0]}" >&2
  local i
  for (( i=1; i<${#cmd[@]}; i++ )); do
    printf ' %q' "${cmd[i]}" >&2
  done
  printf '\n' >&2
  exec "${cmd[@]}"
}

run_stage2_text() {
  local mode profile
  local -a cmd
  mode="$(pick_mode_text)"
  profile="$(pick_profile_text)"
  cmd=("$SCRIPT_DIR/meta/20-stage2-post-reboot.sh" "$mode" --profile "$profile")
  printf 'Running: %q' "${cmd[0]}" >&2
  local i
  for (( i=1; i<${#cmd[@]}; i++ )); do
    printf ' %q' "${cmd[i]}" >&2
  done
  printf '\n' >&2
  exec "${cmd[@]}"
}

run_update_text() {
  local mode
  local -a cmd
  mode="$(pick_mode_text)"
  cmd=("$SCRIPT_DIR/meta/30-update-extras.sh" "$mode")
  printf 'Running: %q' "${cmd[0]}" >&2
  local i
  for (( i=1; i<${#cmd[@]}; i++ )); do
    printf ' %q' "${cmd[i]}" >&2
  done
  printf '\n' >&2
  exec "${cmd[@]}"
}

run_nvidia_text() {
  local mode
  local -a cmd
  mode="$(pick_mode_text)"
  cmd=("$SCRIPT_DIR/nvidia/install-nvidia-cuda.sh" "$mode")
  printf 'Running: %q' "${cmd[0]}" >&2
  local i
  for (( i=1; i<${#cmd[@]}; i++ )); do
    printf ' %q' "${cmd[i]}" >&2
  done
  printf '\n' >&2
  exec "${cmd[@]}"
}

pick_mode_whiptail() {
  local mode_tag
  mode_tag="$(
    whiptail \
    --title "Run Mode" \
    --menu "Choose mode (required)\n\nKeys: ↑↓ select, Enter confirm, Esc cancel." \
    14 72 2 \
    "preview" "dry-run preview only" \
    "execute" "real execution" \
    3>&1 1>&2 2>&3
  )" || return 1

  case "$mode_tag" in
    preview) printf '%s\n' "--check" ;;
    execute) printf '%s\n' "--apply" ;;
    *) return 1 ;;
  esac
}

pick_profile_whiptail() {
  whiptail \
    --title "Stage2 Profile" \
    --menu "Choose profile (required)\n\nKeys: ↑↓ select, Enter confirm, Esc cancel." \
    14 72 2 \
    "desktop" "full desktop workflow (GUI + apps + extras options)" \
    "server" "development/server workflow (no desktop app defaults)" \
    3>&1 1>&2 2>&3
}

run_interactive_menu_whiptail() {
  local action mode profile
  action="$(
    whiptail \
      --title "Linux Setup" \
      --menu "Choose an action\n\nKeys: ↑↓ select, Enter confirm, Esc cancel, Ctrl+C abort." \
      18 84 6 \
      "stage1" "pre-reboot btrfs layout conversion + auto reboot" \
      "stage2" "post-reboot setup (snapper/desnap/upgrade/install/cleanup)" \
      "update" "install or update extras (shell, flatpak, external apps)" \
      "nvidia" "interactive NVIDIA driver + CUDA installer" \
      "preview-all" "dry-run preview for stage1 + stage2 + update" \
      "quit" "exit" \
      3>&1 1>&2 2>&3
  )" || exit 1

  case "$action" in
    stage1)
      mode="$(pick_mode_whiptail)" || exit 1
      restore_tty_after_whiptail
      exec env LINUX_SETUP_FORCE_WHIPTAIL=1 "$SCRIPT_DIR/meta/10-stage1-pre-reboot.sh" "$mode"
      ;;
    stage2)
      mode="$(pick_mode_whiptail)" || exit 1
      profile="$(pick_profile_whiptail)" || exit 1
      restore_tty_after_whiptail
      exec env LINUX_SETUP_FORCE_WHIPTAIL=1 "$SCRIPT_DIR/meta/20-stage2-post-reboot.sh" "$mode" --profile "$profile"
      ;;
    update)
      mode="$(pick_mode_whiptail)" || exit 1
      restore_tty_after_whiptail
      exec env LINUX_SETUP_FORCE_WHIPTAIL=1 "$SCRIPT_DIR/meta/30-update-extras.sh" "$mode"
      ;;
    nvidia)
      mode="$(pick_mode_whiptail)" || exit 1
      restore_tty_after_whiptail
      exec env LINUX_SETUP_FORCE_WHIPTAIL=1 "$SCRIPT_DIR/nvidia/install-nvidia-cuda.sh" "$mode"
      ;;
    preview-all)
      "$SCRIPT_DIR/meta/10-stage1-pre-reboot.sh" --check
      "$SCRIPT_DIR/meta/20-stage2-post-reboot.sh" --check
      "$SCRIPT_DIR/meta/30-update-extras.sh" --check
      exit 0
      ;;
    quit)
      exit 0
      ;;
    *)
      printf 'Unknown interactive action: %s\n' "$action" >&2
      exit 1
      ;;
  esac
}

run_interactive_menu_text() {
  local action
  action="$(pick_action_text)"
  case "$action" in
    stage1)
      run_stage1_text
      ;;
    stage2)
      run_stage2_text
      ;;
    update)
      run_update_text
      ;;
    nvidia)
      run_nvidia_text
      ;;
    preview_all)
      "$SCRIPT_DIR/meta/10-stage1-pre-reboot.sh" --check
      "$SCRIPT_DIR/meta/20-stage2-post-reboot.sh" --check
      "$SCRIPT_DIR/meta/30-update-extras.sh" --check
      exit 0
      ;;
    quit)
      exit 0
      ;;
    *)
      printf 'Unknown interactive action: %s\n' "$action" >&2
      exit 1
      ;;
  esac
}

if [[ $# -eq 0 ]]; then
  has_interactive_tty || {
    usage
    exit 1
  }
  if [[ "${LINUX_SETUP_FORCE_TEXT_UI:-0}" != "1" ]] && supports_whiptail_ui; then
    run_interactive_menu_whiptail
  else
    run_interactive_menu_text
  fi
fi

command_name="$1"
shift

case "$command_name" in
  stage1|s1)
    ensure_explicit_mode_flag "$@"
    exec "$SCRIPT_DIR/meta/10-stage1-pre-reboot.sh" "$@"
    ;;
  stage2|s2)
    ensure_explicit_mode_flag "$@"
    exec "$SCRIPT_DIR/meta/20-stage2-post-reboot.sh" "$@"
    ;;
  update|u|extras)
    ensure_explicit_mode_flag "$@"
    exec "$SCRIPT_DIR/meta/30-update-extras.sh" "$@"
    ;;
  nvidia|nv)
    ensure_explicit_mode_flag "$@"
    exec "$SCRIPT_DIR/nvidia/install-nvidia-cuda.sh" "$@"
    ;;
  check)
    "$SCRIPT_DIR/meta/10-stage1-pre-reboot.sh" --check
    "$SCRIPT_DIR/meta/20-stage2-post-reboot.sh" --check
    "$SCRIPT_DIR/meta/30-update-extras.sh" --check
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    echo "Unknown command: $command_name" >&2
    usage
    exit 1
    ;;
esac
