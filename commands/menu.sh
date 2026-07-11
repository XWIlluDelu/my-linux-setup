#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/lib/runtime.sh"

restore_tty() {
  stty sane 2>/dev/null || true
  tput sgr0 2>/dev/null || true
  tput cnorm 2>/dev/null || true
}

print_command() {
  local arg
  printf 'Running:' >&2
  for arg in "$@"; do
    printf ' %q' "$arg" >&2
  done
  printf '\n' >&2
}

pick_mode_text() {
  local answer
  while true; do
    printf 'Choose mode (preview/execute): ' >&2
    read -r answer
    case "$answer" in
      preview|Preview|PREVIEW|check|Check|CHECK)
        printf '%s\n' --check
        return
        ;;
      execute|Execute|EXECUTE|apply|Apply|APPLY)
        printf '%s\n' --apply
        return
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
        return
        ;;
      server|Server|SERVER)
        printf 'server\n'
        return
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
Linux Manager actions:
  1) setup stage1     - btrfs layout conversion; verify, then reboot manually
  2) setup stage2     - post-reboot setup
  3) update           - full routine update (packages + apps + cleanup)
  4) update apps      - refresh managed apps and shell components
  5) driver nvidia    - interactive NVIDIA driver + CUDA installer
  6) preview-all      - dry-run preview for stage1/stage2/update/apps/nvidia
  7) quit
EOF
  while true; do
    printf 'Choose action [1-7]: ' >&2
    read -r answer
    case "$answer" in
      1) printf 'setup-stage1\n'; return ;;
      2) printf 'setup-stage2\n'; return ;;
      3) printf 'update-all\n'; return ;;
      4) printf 'update-apps\n'; return ;;
      5) printf 'driver-nvidia\n'; return ;;
      6) printf 'preview-all\n'; return ;;
      7) printf 'quit\n'; return ;;
      *) printf 'Please input a number between 1 and 7.\n' >&2 ;;
    esac
  done
}

pick_mode_whiptail() {
  local mode
  mode="$(
    whiptail \
      --title "Run Mode" \
      --menu "Choose mode\n\nKeys: ↑↓ select, Enter confirm, Esc cancel." \
      14 72 2 \
      preview "dry-run preview only" \
      execute "real execution" \
      3>&1 1>&2 2>&3
  )" || return 1
  case "$mode" in
    preview) printf '%s\n' --check ;;
    execute) printf '%s\n' --apply ;;
    *) return 1 ;;
  esac
}

pick_profile_whiptail() {
  whiptail \
    --title "Install Profile" \
    --menu "Choose profile\n\nKeys: ↑↓ select, Enter confirm, Esc cancel." \
    14 72 2 \
    desktop "full desktop workflow (GUI + app defaults)" \
    server "development/server workflow (no desktop app defaults)" \
    3>&1 1>&2 2>&3
}

pick_action_whiptail() {
  whiptail \
    --title "Linux Manager" \
    --menu "Choose an action\n\nKeys: ↑↓ select, Enter confirm, Esc cancel." \
    19 84 7 \
    setup-stage1 "btrfs layout conversion; verify before manual reboot" \
    setup-stage2 "post-reboot setup" \
    update-all "full routine update (packages + apps + cleanup)" \
    update-apps "refresh managed apps and shell components" \
    driver-nvidia "interactive NVIDIA driver + CUDA installer" \
    preview-all "dry-run preview for stage1/stage2/update/apps/nvidia" \
    quit "exit" \
    3>&1 1>&2 2>&3
}

run_action() {
  local action mode profile mode_picker profile_picker
  action="$1"
  mode_picker="$2"
  profile_picker="$3"

  case "$action" in
    setup-stage1)
      mode="$($mode_picker)" || exit 1
      set -- setup stage1 "$mode"
      ;;
    setup-stage2)
      mode="$($mode_picker)" || exit 1
      profile="$($profile_picker)" || exit 1
      set -- setup stage2 "$mode" --profile "$profile"
      ;;
    update-all)
      mode="$($mode_picker)" || exit 1
      set -- update "$mode"
      ;;
    update-apps)
      mode="$($mode_picker)" || exit 1
      set -- update apps "$mode"
      ;;
    driver-nvidia)
      mode="$($mode_picker)" || exit 1
      set -- driver nvidia "$mode"
      ;;
    preview-all)
      set -- check
      ;;
    quit)
      exit 0
      ;;
    *)
      die "Unknown interactive action: $action"
      ;;
  esac

  restore_tty
  print_command "$ROOT_DIR/manage.sh" "$@"
  if [[ "$mode_picker" == pick_mode_whiptail ]]; then
    exec env LINUX_SETUP_FORCE_WHIPTAIL=1 "$ROOT_DIR/manage.sh" "$@"
  fi
  exec "$ROOT_DIR/manage.sh" "$@"
}

has_interactive_tty || die "Interactive menu requires a terminal. Use manage.sh --help for commands."

if [[ "${LINUX_SETUP_FORCE_TEXT_UI:-0}" != 1 ]] && supports_whiptail_ui; then
  action="$(pick_action_whiptail)" || exit 1
  run_action "$action" pick_mode_whiptail pick_profile_whiptail
else
  action="$(pick_action_text)"
  run_action "$action" pick_mode_text pick_profile_text
fi
