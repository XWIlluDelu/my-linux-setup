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

die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Linux setup and management entrypoint.

Usage:
  manage.sh
  manage.sh setup stage1 [args...]
  manage.sh setup stage2 [args...]
  manage.sh driver nvidia [args...]
  manage.sh update [args...]
  manage.sh update packages [args...]
  manage.sh update apps [args...]
  manage.sh maintain repair [args...]
  manage.sh maintain mirror [args...]
  manage.sh snapshot create [args...]
  manage.sh snapshot rollback [args...]
  manage.sh shell sync [args...]
  manage.sh check

Examples:
  manage.sh setup stage1 --apply
  manage.sh setup stage2 --apply --profile desktop
  manage.sh update --apply
  manage.sh update packages --apply
  manage.sh update apps --apply
  manage.sh driver nvidia --apply
  manage.sh shell sync --apply --profile server

Notes:
  - Running `manage.sh` without arguments opens an interactive menu.
  - Interactive mode focuses on the main install/update flows.
  - Subcommands inherit the target script defaults, which are usually `--check`.
EOF
}

print_running_command() {
  local arg
  printf 'Running:' >&2
  for arg in "$@"; do
    printf ' %q' "$arg" >&2
  done
  printf '\n' >&2
}

run_preview_suite() {
  bash "$SCRIPT_DIR/flows/install-stage1.sh" --check
  bash "$SCRIPT_DIR/flows/install-stage2.sh" --check
  bash "$SCRIPT_DIR/commands/update/update-all.sh" --check
  bash "$SCRIPT_DIR/flows/update-apps.sh" --check
  bash "$SCRIPT_DIR/drivers/nvidia/install-nvidia-cuda.sh" --check
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
Linux Manager actions:
  1) setup stage1     - btrfs layout conversion + reboot
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
      1) printf 'setup_stage1\n'; return 0 ;;
      2) printf 'setup_stage2\n'; return 0 ;;
      3) printf 'update_all\n'; return 0 ;;
      4) printf 'update_apps\n'; return 0 ;;
      5) printf 'driver_nvidia\n'; return 0 ;;
      6) printf 'preview_all\n'; return 0 ;;
      7) printf 'quit\n'; return 0 ;;
      *) printf 'Please input a number between 1 and 7.\n' >&2 ;;
    esac
  done
}

pick_mode_whiptail() {
  local mode_tag
  mode_tag="$(
    whiptail \
      --title "Run Mode" \
      --menu "Choose mode\n\nKeys: ↑↓ select, Enter confirm, Esc cancel." \
      14 72 2 \
      "preview" "dry-run preview only" \
      "execute" "real execution" \
      3>&1 1>&2 2>&3
  )" || return 1

  case "$mode_tag" in
    preview) printf '%s\n' '--check' ;;
    execute) printf '%s\n' '--apply' ;;
    *) return 1 ;;
  esac
}

pick_profile_whiptail() {
  whiptail \
    --title "Install Profile" \
    --menu "Choose profile\n\nKeys: ↑↓ select, Enter confirm, Esc cancel." \
    14 72 2 \
    "desktop" "full desktop workflow (GUI + app defaults)" \
    "server" "development/server workflow (no desktop app defaults)" \
    3>&1 1>&2 2>&3
}

run_interactive_menu_text() {
  local action mode profile
  action="$(pick_action_text)"

  case "$action" in
    setup_stage1)
      mode="$(pick_mode_text)"
      print_running_command "$SCRIPT_DIR/flows/install-stage1.sh" "$mode"
      exec "$SCRIPT_DIR/flows/install-stage1.sh" "$mode"
      ;;
    setup_stage2)
      mode="$(pick_mode_text)"
      profile="$(pick_profile_text)"
      print_running_command "$SCRIPT_DIR/flows/install-stage2.sh" "$mode" --profile "$profile"
      exec "$SCRIPT_DIR/flows/install-stage2.sh" "$mode" --profile "$profile"
      ;;
    update_all)
      mode="$(pick_mode_text)"
      print_running_command "$SCRIPT_DIR/commands/update/update-all.sh" "$mode"
      exec "$SCRIPT_DIR/commands/update/update-all.sh" "$mode"
      ;;
    update_apps)
      mode="$(pick_mode_text)"
      print_running_command "$SCRIPT_DIR/flows/update-apps.sh" "$mode"
      exec "$SCRIPT_DIR/flows/update-apps.sh" "$mode"
      ;;
    driver_nvidia)
      mode="$(pick_mode_text)"
      print_running_command "$SCRIPT_DIR/drivers/nvidia/install-nvidia-cuda.sh" "$mode"
      exec "$SCRIPT_DIR/drivers/nvidia/install-nvidia-cuda.sh" "$mode"
      ;;
    preview_all)
      run_preview_suite
      exit 0
      ;;
    quit)
      exit 0
      ;;
    *)
      die "Unknown interactive action: $action"
      ;;
  esac
}

run_interactive_menu_whiptail() {
  local action mode profile
  action="$(
    whiptail \
      --title "Linux Manager" \
      --menu "Choose an action\n\nKeys: ↑↓ select, Enter confirm, Esc cancel." \
      19 84 7 \
      "setup-stage1" "btrfs layout conversion + reboot" \
      "setup-stage2" "post-reboot setup" \
      "update-all" "full routine update (packages + apps + cleanup)" \
      "update-apps" "refresh managed apps and shell components" \
      "driver-nvidia" "interactive NVIDIA driver + CUDA installer" \
      "preview-all" "dry-run preview for stage1/stage2/update/apps/nvidia" \
      "quit" "exit" \
      3>&1 1>&2 2>&3
  )" || exit 1

  case "$action" in
    setup-stage1)
      mode="$(pick_mode_whiptail)" || exit 1
      restore_tty_after_whiptail
      exec env LINUX_SETUP_FORCE_WHIPTAIL=1 "$SCRIPT_DIR/flows/install-stage1.sh" "$mode"
      ;;
    setup-stage2)
      mode="$(pick_mode_whiptail)" || exit 1
      profile="$(pick_profile_whiptail)" || exit 1
      restore_tty_after_whiptail
      exec env LINUX_SETUP_FORCE_WHIPTAIL=1 "$SCRIPT_DIR/flows/install-stage2.sh" "$mode" --profile "$profile"
      ;;
    update-all)
      mode="$(pick_mode_whiptail)" || exit 1
      restore_tty_after_whiptail
      exec env LINUX_SETUP_FORCE_WHIPTAIL=1 "$SCRIPT_DIR/commands/update/update-all.sh" "$mode"
      ;;
    update-apps)
      mode="$(pick_mode_whiptail)" || exit 1
      restore_tty_after_whiptail
      exec env LINUX_SETUP_FORCE_WHIPTAIL=1 "$SCRIPT_DIR/flows/update-apps.sh" "$mode"
      ;;
    driver-nvidia)
      mode="$(pick_mode_whiptail)" || exit 1
      restore_tty_after_whiptail
      exec env LINUX_SETUP_FORCE_WHIPTAIL=1 "$SCRIPT_DIR/drivers/nvidia/install-nvidia-cuda.sh" "$mode"
      ;;
    preview-all)
      restore_tty_after_whiptail
      run_preview_suite
      exit 0
      ;;
    quit)
      exit 0
      ;;
    *)
      die "Unknown interactive action: $action"
      ;;
  esac
}

dispatch() {
  local area action
  area="${1:-}"
  action="${2:-}"

  case "$area" in
    setup)
      case "$action" in
        stage1)
          shift 2
          exec "$SCRIPT_DIR/flows/install-stage1.sh" "$@"
          ;;
        stage2)
          shift 2
          exec "$SCRIPT_DIR/flows/install-stage2.sh" "$@"
          ;;
        *)
          die "Unknown setup target: ${action:-<missing>}"
          ;;
      esac
      ;;
    driver)
      case "$action" in
        nvidia|gpu)
          shift 2
          exec "$SCRIPT_DIR/drivers/nvidia/install-nvidia-cuda.sh" "$@"
          ;;
        *)
          die "Unknown driver target: ${action:-<missing>}"
          ;;
      esac
      ;;
    update)
      case "$action" in
        "")
          shift 1
          exec "$SCRIPT_DIR/commands/update/update-all.sh" "$@"
          ;;
        -*|--*)
          shift 1
          exec "$SCRIPT_DIR/commands/update/update-all.sh" "$action" "$@"
          ;;
        all)
          shift 2
          exec "$SCRIPT_DIR/commands/update/update-all.sh" "$@"
          ;;
        packages|package)
          shift 2
          exec "$SCRIPT_DIR/commands/update/update-packages.sh" "$@"
          ;;
        apps|app)
          shift 2
          exec "$SCRIPT_DIR/flows/update-apps.sh" "$@"
          ;;
        *)
          die "Unknown update target: ${action:-<missing>}"
          ;;
      esac
      ;;
    maintain)
      case "$action" in
        repair)
          shift 2
          exec "$SCRIPT_DIR/commands/maintenance/repair-system.sh" "$@"
          ;;
        mirror|apt-mirror)
          shift 2
          exec "$SCRIPT_DIR/commands/maintenance/set-apt-mirror.sh" "$@"
          ;;
        *)
          die "Unknown maintenance target: ${action:-<missing>}"
          ;;
      esac
      ;;
    snapshot)
      case "$action" in
        create)
          shift 2
          exec "$SCRIPT_DIR/commands/snapshots/create-snapshot.sh" "$@"
          ;;
        rollback)
          shift 2
          exec "$SCRIPT_DIR/commands/snapshots/rollback.sh" "$@"
          ;;
        *)
          die "Unknown snapshot target: ${action:-<missing>}"
          ;;
      esac
      ;;
    shell)
      case "$action" in
        sync)
          shift 2
          exec "$SCRIPT_DIR/commands/shell/sync-shell-config.sh" "$@"
          ;;
        *)
          die "Unknown shell target: ${action:-<missing>}"
          ;;
      esac
      ;;
    check)
      run_preview_suite
      ;;
    help|-h|--help)
      usage
      ;;
    *)
      die "Unknown command group: ${area:-<missing>}"
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

dispatch "$@"
