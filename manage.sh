#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$ROOT_DIR/lib/runtime.sh"

usage() {
  cat <<'EOF'
Linux setup and management entrypoint.

Primary setup commands:
  manage.sh setup stage1 [args...]
  manage.sh setup stage2 [args...]
  manage.sh driver nvidia [args...]

Post-install commands:
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
  manage.sh driver nvidia --apply

Run without arguments for the optional interactive menu. Commands default to
--check unless their help states otherwise.
EOF
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
          exec "$ROOT_DIR/commands/setup/stage1.sh" "$@"
          ;;
        stage2)
          shift 2
          exec "$ROOT_DIR/commands/setup/stage2.sh" "$@"
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
          exec "$ROOT_DIR/drivers/nvidia/install-nvidia-cuda.sh" "$@"
          ;;
        *)
          die "Unknown driver target: ${action:-<missing>}"
          ;;
      esac
      ;;
    update)
      case "$action" in
        '')
          shift
          exec "$ROOT_DIR/commands/update/all.sh" "$@"
          ;;
        -*|--*)
          shift
          exec "$ROOT_DIR/commands/update/all.sh" "$action" "$@"
          ;;
        all)
          shift 2
          exec "$ROOT_DIR/commands/update/all.sh" "$@"
          ;;
        packages|package)
          shift 2
          exec "$ROOT_DIR/commands/update/packages.sh" "$@"
          ;;
        apps|app)
          shift 2
          exec "$ROOT_DIR/commands/update/apps.sh" "$@"
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
          exec "$ROOT_DIR/commands/maintain/repair.sh" "$@"
          ;;
        mirror|apt-mirror)
          shift 2
          exec "$ROOT_DIR/commands/maintain/mirror.sh" "$@"
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
          exec "$ROOT_DIR/commands/snapshot/create.sh" "$@"
          ;;
        rollback)
          shift 2
          exec "$ROOT_DIR/commands/snapshot/rollback.sh" "$@"
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
          exec "$ROOT_DIR/commands/shell/sync.sh" "$@"
          ;;
        *)
          die "Unknown shell target: ${action:-<missing>}"
          ;;
      esac
      ;;
    check)
      shift
      exec "$ROOT_DIR/commands/check.sh" "$@"
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
  exec "$ROOT_DIR/commands/menu.sh"
fi

dispatch "$@"
