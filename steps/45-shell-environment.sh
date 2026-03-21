#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

ASSET_DIR="$SCRIPT_DIR/../assets/shell"
PROFILE="desktop"
PROFILE_EXPLICIT=0
UPDATE_ONLY=0
TMP_DIR=""
PKG_MANAGER=""

cleanup() {
  if [[ -n "${TMP_DIR:-}" && -d "${TMP_DIR:-}" ]]; then
    rm -rf "$TMP_DIR"
  fi
}
trap cleanup EXIT

usage() {
  cat <<'EOF'
Install and configure the shared tmux/zsh shell environment.

Usage:
  45-shell-environment.sh [--check] [--apply] [--profile desktop|server] [--update-only]

Notes:
  - Default mode is --check.
  - Package install path supports apt, dnf, zypper, and pacman.
EOF
}

detect_shell_pkg_manager() {
  PKG_MANAGER="$(detect_pkg_manager 2>/dev/null || true)"
}

shell_pkg_manager_label() {
  if [[ -z "${PKG_MANAGER:-}" ]]; then
    detect_shell_pkg_manager
  fi

  case "${PKG_MANAGER:-}" in
    apt-get)
      printf 'apt\n'
      ;;
    dnf|zypper|pacman)
      printf '%s\n' "$PKG_MANAGER"
      ;;
    *)
      printf 'supported package manager\n'
      ;;
  esac
}

install_shell_packages() {
  local optional_pkg
  local -a packages

  detect_shell_pkg_manager
  [[ -n "$PKG_MANAGER" ]] || die "No supported package manager detected. Supported: apt, dnf, zypper, pacman."

  packages=(zsh tmux)
  for optional_pkg in fzf trash-cli; do
    if package_available "$optional_pkg" "$PKG_MANAGER"; then
      packages+=("$optional_pkg")
    else
      warn "[shell] Package not available via ${PKG_MANAGER}, skipped: $optional_pkg"
    fi
  done

  info "[shell] Ensure shell packages via $(shell_pkg_manager_label)"
  install_packages "${packages[@]}"
}

get_login_shell() {
  local user login_shell
  user="$1"

  login_shell="$(getent passwd "$user" 2>/dev/null | cut -d: -f7 || true)"
  if [[ -z "$login_shell" ]]; then
    login_shell="$(awk -F: -v user="$user" '$1 == user { print $7 }' /etc/passwd 2>/dev/null || true)"
  fi
  printf '%s\n' "$login_shell"
}

ensure_zinit_repo() {
  local target_user target_home zinit_dir
  target_user="$1"
  target_home="$2"
  zinit_dir="$target_home/.local/share/zinit/zinit.git"

  run_as_target_user "$target_user" "$target_home" mkdir -p "$(dirname "$zinit_dir")"
  if [[ -d "$zinit_dir/.git" ]]; then
    info "[shell] Update zinit"
    run_as_target_user "$target_user" "$target_home" git -C "$zinit_dir" pull --ff-only
  else
    info "[shell] Install zinit"
    run_as_target_user "$target_user" "$target_home" git clone https://github.com/zdharma-continuum/zinit "$zinit_dir"
  fi
}

install_starship() {
  local target_user target_home script_path
  target_user="$1"
  target_home="$2"
  script_path="$TMP_DIR/starship-install.sh"

  info "[shell] Install or update starship"
  download_url_with_speed_guard "https://starship.rs/install.sh" "$script_path"
  chmod 644 "$script_path"
  run_as_target_user "$target_user" "$target_home" mkdir -p "$target_home/.local/bin"
  run_as_target_user "$target_user" "$target_home" sh "$script_path" -y -b "$target_home/.local/bin"
}

clean_shell_env_user_state() {
  local target_user target_home state_dir state_file marker_file
  target_user="$1"
  target_home="$2"
  state_dir="$(linux_setup_state_dir_for_home "$target_home")"
  state_file="$(shell_env_state_file_for_home "$target_home")"
  marker_file="$(shell_env_profile_marker_for_home "$target_home")"

  info "[shell] Remove managed shell configuration and user-space shell components"
  run_as_target_user "$target_user" "$target_home" rm -f \
    "$target_home/.zshrc" \
    "$target_home/.tmux.conf" \
    "$target_home/.config/starship.toml" \
    "$target_home/.local/bin/starship" \
    "$target_home/.zcompdump" \
    "$target_home/.zcompdump.zwc" \
    "$state_file" \
    "$marker_file"
  run_as_target_user "$target_user" "$target_home" rm -rf \
    "$target_home/.local/share/zinit"
  run_as_target_user "$target_user" "$target_home" mkdir -p \
    "$target_home/.config" \
    "$target_home/.local/bin" \
    "$state_dir"
}

apply_shell_assets() {
  local target_user target_home zsh_source bash_source profile_source marker_path state_dir state_file timestamp
  target_user="$1"
  target_home="$2"

  case "$PROFILE" in
    desktop)
      bash_source="$ASSET_DIR/bashrc.desktop"
      zsh_source="$ASSET_DIR/zshrc.desktop"
      ;;
    server)
      bash_source="$ASSET_DIR/bashrc.server"
      zsh_source="$ASSET_DIR/zshrc.server"
      ;;
    *)
      die "Unsupported shell profile: $PROFILE"
      ;;
  esac
  profile_source="$ASSET_DIR/profile"

  run_as_target_user "$target_user" "$target_home" mkdir -p "$target_home/.config"
  state_dir="$(linux_setup_state_dir_for_home "$target_home")"
  state_file="$(shell_env_state_file_for_home "$target_home")"
  run_as_target_user "$target_user" "$target_home" mkdir -p "$state_dir"
  run_as_target_user "$target_user" "$target_home" install -m 644 "$profile_source" "$target_home/.profile"
  run_as_target_user "$target_user" "$target_home" install -m 644 "$bash_source" "$target_home/.bashrc"
  run_as_target_user "$target_user" "$target_home" install -m 644 "$zsh_source" "$target_home/.zshrc"
  run_as_target_user "$target_user" "$target_home" install -m 644 "$ASSET_DIR/tmux.conf" "$target_home/.tmux.conf"
  run_as_target_user "$target_user" "$target_home" install -m 644 "$ASSET_DIR/starship.toml" "$target_home/.config/starship.toml"
  timestamp="$(date +%Y-%m-%dT%H:%M:%S%:z)"
  marker_path="$(shell_env_profile_marker_for_home "$target_home")"
  run_as_target_user "$target_user" "$target_home" sh -c "printf '%s\n' '$PROFILE' > '$marker_path'"
  run_as_target_user "$target_user" "$target_home" sh -c "cat > '$state_file' <<'EOF'
SHELL_ENV_MANAGED=1
SHELL_ENV_PROFILE=$PROFILE
SHELL_ENV_LAST_APPLIED_AT=$timestamp
EOF"
}

change_default_shell_to_zsh() {
  local target_user zsh_path current_login_shell
  target_user="$1"
  zsh_path="$(command -v zsh)"
  current_login_shell="$(get_login_shell "$target_user")"

  if [[ "$current_login_shell" == "$zsh_path" ]]; then
    info "[shell] Default shell is already zsh for $target_user"
    return 0
  fi

  if ! grep -qx "$zsh_path" /etc/shells 2>/dev/null; then
    warn "[shell] $zsh_path is not listed in /etc/shells; chsh may fail."
  fi

  if as_root chsh -s "$zsh_path" "$target_user"; then
    info "[shell] Default shell changed to zsh for $target_user"
  else
    warn "[shell] Failed to change the default shell to zsh for $target_user"
  fi
}

preload_zsh_plugins() {
  local target_user target_home
  target_user="$1"
  target_home="$2"

  info "[shell] Preload zsh plugins"
  run_as_target_user "$target_user" "$target_home" zsh -i -c 'exit' >/dev/null 2>&1 || \
    warn "[shell] Zinit preload was skipped; plugins will initialize on the first interactive zsh run."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)
      APPLY=0
      ;;
    --apply)
      APPLY=1
      ;;
    --profile)
      [[ $# -ge 2 ]] || die "--profile requires a value"
      case "$2" in
        desktop|server)
          PROFILE="$2"
          PROFILE_EXPLICIT=1
          ;;
        *)
          die "--profile must be desktop or server"
          ;;
      esac
      shift
      ;;
    --update-only)
      UPDATE_ONLY=1
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

TARGET_USER="$(resolve_target_user)"
TARGET_HOME="$(resolve_target_home "$TARGET_USER")"

if [[ "$PROFILE_EXPLICIT" -ne 1 ]]; then
  recorded_profile="$(shell_env_profile_from_state_or_marker "$TARGET_HOME" 2>/dev/null || true)"
  if [[ -n "$recorded_profile" ]]; then
    PROFILE="$recorded_profile"
  fi
fi

if [[ "$UPDATE_ONLY" -eq 1 ]] && ! detect_managed_shell_env "$TARGET_HOME"; then
  die "shell_env is not managed by linux-setup for $TARGET_HOME."
fi

if [[ "$APPLY" -ne 1 ]]; then
  cat <<EOF
This was a check run. The script would:
  1. $( [[ "$UPDATE_ONLY" -eq 1 ]] && printf 'Skip package installation and default-shell changes' || printf 'Ensure shell packages are installed via %s' "$(shell_pkg_manager_label)" )
  2. Remove existing managed shell config files and user-space shell components in ${TARGET_HOME}
  3. Reinstall starship in ${TARGET_HOME}/.local/bin
  4. Reinstall zinit in ${TARGET_HOME}/.local/share/zinit/zinit.git
  5. Write managed ~/.profile, ${PROFILE}-specific ~/.bashrc and ~/.zshrc, ~/.tmux.conf, ~/.config/starship.toml, and shell state markers
  6. $( [[ "$UPDATE_ONLY" -eq 1 ]] && printf 'Preload zsh plugins for the target user' || printf 'Try to switch the default shell for %s to zsh' "$TARGET_USER" )
  7. $( [[ "$UPDATE_ONLY" -eq 1 ]] && printf 'Finish without touching system packages or chsh' || printf 'Preload zsh plugins for the target user' )

Run with --apply to execute.
EOF
  exit 0
fi

ensure_command git
ensure_command curl
ensure_command install
ensure_command sh

if [[ "$(id -un)" != "$TARGET_USER" ]]; then
  ensure_sudo_session
fi

detect_shell_pkg_manager

TMP_DIR="$(mktemp -d)"
chmod 755 "$TMP_DIR"
if [[ "$UPDATE_ONLY" -ne 1 ]]; then
  [[ -n "$PKG_MANAGER" ]] || die "No supported package manager detected. Supported: apt, dnf, zypper, pacman."
  ensure_sudo_session
  install_shell_packages
fi

clean_shell_env_user_state "$TARGET_USER" "$TARGET_HOME"
install_starship "$TARGET_USER" "$TARGET_HOME"
ensure_zinit_repo "$TARGET_USER" "$TARGET_HOME"
apply_shell_assets "$TARGET_USER" "$TARGET_HOME"
if [[ "$UPDATE_ONLY" -ne 1 ]]; then
  change_default_shell_to_zsh "$TARGET_USER"
fi
preload_zsh_plugins "$TARGET_USER" "$TARGET_HOME"
