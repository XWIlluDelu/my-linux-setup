#!/usr/bin/env bash

# Command execution, privilege, target-user, and terminal primitives.

APPLY="${APPLY:-0}"

info() {
  printf '[INFO] %s\n' "$*"
}
warn() {
  printf '[WARN] %s\n' "$*" >&2
}
die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}
quote_cmd() {
  local out=()
  local arg
  for arg in "$@"; do
    out+=("$(printf '%q' "$arg")")
  done
  printf '%s' "${out[*]}"
}
run() {
  if [[ "$APPLY" -eq 1 ]]; then
    info "+ $(quote_cmd "$@")"
    "$@"
    return
  fi

  info "[dry-run] $(quote_cmd "$@")"
}
run_as_root() {
  if [[ "$EUID" -eq 0 ]]; then
    run "$@"
  else
    run sudo "$@"
  fi
}
try_run() {
  if [[ "$APPLY" -eq 1 ]]; then
    info "+ $(quote_cmd "$@")"
    "$@" || warn "Command failed, continuing: $(quote_cmd "$@")"
    return
  fi

  info "[dry-run] $(quote_cmd "$@")"
}
try_run_as_root() {
  if [[ "$EUID" -eq 0 ]]; then
    try_run "$@"
  else
    try_run sudo "$@"
  fi
}
ensure_sudo_session() {
  if [[ "$EUID" -ne 0 ]]; then
    if ! sudo -n true >/dev/null 2>&1; then
      sudo -v
    fi
    sudo_keepalive_start
  fi
}
sudo_keepalive_start() {
  local interval parent_pid

  if [[ "$EUID" -eq 0 ]]; then
    return 0
  fi

  if [[ "${LINUX_SETUP_SUDO_KEEPALIVE_ACTIVE:-0}" == "1" ]]; then
    return 0
  fi

  interval=30
  parent_pid="$BASHPID"
  export LINUX_SETUP_SUDO_KEEPALIVE_ACTIVE=1

  (
    while kill -0 "$parent_pid" 2>/dev/null; do
      sudo -n true >/dev/null 2>&1 || exit 0
      sleep "$interval"
    done
  ) >/dev/null 2>&1 &
}
ensure_command() {
  command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}
command_exists() {
  command -v "$1" >/dev/null 2>&1
}
resolve_target_user() {
  printf '%s\n' "${1:-${LINUX_SETUP_TARGET_USER:-${SUDO_USER:-$(id -un)}}}"
}
resolve_target_home() {
  local target_user home_path
  target_user="${1:-$(resolve_target_user)}"

  home_path="$(getent passwd "$target_user" 2>/dev/null | cut -d: -f6 || true)"
  if [[ -z "$home_path" ]]; then
    home_path="$(awk -F: -v user="$target_user" '$1 == user { print $6 }' /etc/passwd 2>/dev/null || true)"
  fi
  if [[ -z "$home_path" ]]; then
    home_path="${HOME:-}"
  fi

  [[ -n "$home_path" ]] || die "Could not determine the home directory for user '$target_user'."
  printf '%s\n' "$home_path"
}
run_as_target_user() {
  local target_user target_home
  target_user="$1"
  target_home="$2"
  shift 2

  if [[ "$(id -un)" == "$target_user" ]]; then
    env HOME="$target_home" USER="$target_user" "$@"
  else
    sudo -u "$target_user" env HOME="$target_home" USER="$target_user" "$@"
  fi
}
has_interactive_tty() {
  [[ -t 0 && -t 1 ]]
}
has_interactive_input_tty() {
  [[ -t 0 ]]
}
supports_whiptail_ui() {
  if [[ "${LINUX_SETUP_NO_WHIPTAIL:-0}" == "1" ]]; then
    return 1
  fi

  has_interactive_tty || return 1
  command_exists whiptail || return 1

  [[ -n "${TERM:-}" ]] || return 1
  [[ "${TERM:-}" != "dumb" ]] || return 1

  if [[ "${LINUX_SETUP_FORCE_WHIPTAIL:-0}" == "1" ]]; then
    return 0
  fi

  if command_exists tput; then
    local cols lines
    cols=$(tput cols 2>/dev/null || echo 0)
    lines=$(tput lines 2>/dev/null || echo 0)
    [[ "$cols" -ge 60 && "$lines" -ge 16 ]] || return 1
  fi

  return 0
}
prompt_bool_text() {
  local __var_name prompt default answer
  __var_name="$1"
  prompt="$2"
  default="$3"

  while true; do
    if [[ "$default" -eq 1 ]]; then
      printf '%s' "$prompt [Y/n]: " >&2
    else
      printf '%s' "$prompt [y/N]: " >&2
    fi
    read -r answer
    case "$answer" in
      '')
        printf -v "$__var_name" '%s' "$default"
        return 0
        ;;
      y|Y|yes|YES)
        printf -v "$__var_name" '1'
        return 0
        ;;
      n|N|no|NO)
        printf -v "$__var_name" '0'
        return 0
        ;;
      *)
        printf 'Please answer y or n.\n' >&2
        ;;
    esac
  done
}
as_root() {
  if [[ "$EUID" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}
detect_os_release() {
  DISTRO_ID="unknown"
  DISTRO_PRETTY="unknown"

  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    DISTRO_ID="${ID:-unknown}"
    DISTRO_PRETTY="${PRETTY_NAME:-$DISTRO_ID}"
  fi
}
