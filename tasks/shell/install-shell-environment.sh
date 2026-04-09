#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

ASSET_DIR="$SCRIPT_DIR/../../assets/shell"
PROFILE="desktop"
PROFILE_EXPLICIT=0
UPDATE_ONLY=0
CONFIG_ONLY=0
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
  install-shell-environment.sh [--check] [--apply] [--profile desktop|server] [--update-only] [--config-only]

Notes:
  - Default mode is --check.
  - Package install path supports apt, dnf, zypper, and pacman.
  - `--update-only` refreshes managed shell components, ensures shell tool packages, and skips login-shell changes.
  - `--config-only` only rewrites managed shell config files and state markers.
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

shell_package_candidates() {
  local tool_key
  tool_key="$1"

  case "$tool_key:$PKG_MANAGER" in
    eza:apt-get|eza:dnf|eza:zypper|eza:pacman)
      printf '%s\n' eza
      ;;
    bat:apt-get|bat:dnf|bat:zypper|bat:pacman)
      printf '%s\n' bat batcat
      ;;
    ripgrep:apt-get|ripgrep:dnf|ripgrep:zypper|ripgrep:pacman)
      printf '%s\n' ripgrep
      ;;
    fd:apt-get|fd:dnf)
      printf '%s\n' fd-find fd
      ;;
    fd:zypper|fd:pacman)
      printf '%s\n' fd fd-find
      ;;
    fzf:apt-get|fzf:dnf|fzf:zypper|fzf:pacman)
      printf '%s\n' fzf
      ;;
    trash-cli:apt-get|trash-cli:dnf|trash-cli:zypper|trash-cli:pacman)
      printf '%s\n' trash-cli
      ;;
    *)
      return 1
      ;;
  esac
}

resolve_shell_package() {
  local tool_key candidate
  tool_key="$1"

  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    if package_available "$candidate" "$PKG_MANAGER"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done < <(shell_package_candidates "$tool_key")

  return 1
}

install_shell_packages() {
  local tool_key resolved_package
  local -a packages modern_tool_keys

  detect_shell_pkg_manager
  [[ -n "$PKG_MANAGER" ]] || die "No supported package manager detected. Supported: apt, dnf, zypper, pacman."

  packages=(zsh tmux)
  modern_tool_keys=(eza ripgrep bat fd fzf trash-cli)

  for tool_key in "${modern_tool_keys[@]}"; do
    if resolved_package="$(resolve_shell_package "$tool_key")"; then
      packages+=("$resolved_package")
    else
      warn "[shell] No supported package candidate available via ${PKG_MANAGER}, skipped tool: $tool_key"
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
    --config-only)
      CONFIG_ONLY=1
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

if [[ "$UPDATE_ONLY" -eq 1 && "$CONFIG_ONLY" -eq 1 ]]; then
  die "--update-only and --config-only cannot be used together"
fi

if [[ "$PROFILE_EXPLICIT" -ne 1 ]]; then
  recorded_profile="$(shell_env_profile_from_state_or_marker "$TARGET_HOME" 2>/dev/null || true)"
  if [[ -n "$recorded_profile" ]]; then
    PROFILE="$recorded_profile"
  fi
fi

if [[ "$UPDATE_ONLY" -eq 1 ]] && ! detect_managed_shell_env "$TARGET_HOME"; then
  die "shell_env is not managed by linux-setup for $TARGET_HOME."
fi

if [[ "$CONFIG_ONLY" -eq 1 ]] && ! detect_managed_shell_env "$TARGET_HOME"; then
  die "shell_env config-only refresh requires an existing linux-setup-managed shell environment at $TARGET_HOME."
fi

if [[ "$APPLY" -ne 1 ]]; then
  if [[ "$CONFIG_ONLY" -eq 1 ]]; then
    cat <<EOF
This was a check run. The script would:
  1. Skip package installation, starship/zinit refresh, and default-shell changes
  2. Rewrite managed ~/.profile, ${PROFILE}-specific ~/.bashrc and ~/.zshrc, ~/.tmux.conf, ~/.config/starship.toml, and shell state markers in ${TARGET_HOME}
  3. Preserve the existing starship binary and zinit checkout

Run with --apply to execute.
EOF
  else
    cat <<EOF
This was a check run. The script would:
  1. Ensure shell packages are installed via $(shell_pkg_manager_label)
  2. Remove existing managed shell config files and user-space shell components in ${TARGET_HOME}
  3. Reinstall starship in ${TARGET_HOME}/.local/bin
  4. Reinstall zinit in ${TARGET_HOME}/.local/share/zinit/zinit.git
  5. Write managed ~/.profile, ${PROFILE}-specific ~/.bashrc and ~/.zshrc, ~/.tmux.conf, ~/.config/starship.toml, and shell state markers
  6. $( [[ "$UPDATE_ONLY" -eq 1 ]] && printf 'Skip default-shell changes for %s' "$TARGET_USER" || printf 'Try to switch the default shell for %s to zsh' "$TARGET_USER" )
  7. Preload zsh plugins for the target user

Run with --apply to execute.
EOF
  fi
  exit 0
fi

ensure_command install
ensure_command sh

if [[ "$(id -un)" != "$TARGET_USER" ]]; then
  ensure_sudo_session
fi

if [[ "$CONFIG_ONLY" -eq 1 ]]; then
  apply_shell_assets "$TARGET_USER" "$TARGET_HOME"
  info "[shell] Managed shell config files refreshed for $TARGET_USER"
  exit 0
fi

ensure_command git
ensure_command curl

detect_shell_pkg_manager

TMP_DIR="$(mktemp -d)"
chmod 755 "$TMP_DIR"
[[ -n "$PKG_MANAGER" ]] || die "No supported package manager detected. Supported: apt, dnf, zypper, pacman."
ensure_sudo_session
install_shell_packages

clean_shell_env_user_state "$TARGET_USER" "$TARGET_HOME"
install_starship "$TARGET_USER" "$TARGET_HOME"
ensure_zinit_repo "$TARGET_USER" "$TARGET_HOME"
apply_shell_assets "$TARGET_USER" "$TARGET_HOME"
if [[ "$UPDATE_ONLY" -ne 1 ]]; then
  change_default_shell_to_zsh "$TARGET_USER"
fi
preload_zsh_plugins "$TARGET_USER" "$TARGET_HOME"
