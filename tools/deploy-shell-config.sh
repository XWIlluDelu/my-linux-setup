#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
source "$ROOT_DIR/lib/common.sh"

ASSET_DIR="$ROOT_DIR/assets/shell"
PROFILE=""
PROFILE_EXPLICIT=0
TMP_DIR=""

cleanup() {
  if [[ -n "${TMP_DIR:-}" && -d "${TMP_DIR:-}" ]]; then
    rm -rf "$TMP_DIR"
  fi
}
trap cleanup EXIT

usage() {
  cat <<'EOF'
Deploy shell configuration files.

Usage:
  deploy-shell-config.sh [--check] [--apply] [--profile desktop|server]

Deploys:
  - ~/.profile from assets (shared, managed)
  - ~/.bashrc from assets (profile-specific, managed)
  - ~/.zshrc from assets (custom, profile-specific)
  - ~/.tmux.conf from assets (custom)
  - ~/.config/starship.toml from assets (custom)
  - starship binary to ~/.local/bin (install or update)
  - zinit to ~/.local/share/zinit (install or update)

Notes:
  - Default mode is --check.
  - Every run overwrites the config files with the latest version.
  - Does not install APT packages or change the default shell.
  - If no --profile is given, reads from existing state or defaults to desktop.
EOF
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

# Resolve profile: explicit > recorded state > default
if [[ "$PROFILE_EXPLICIT" -ne 1 ]]; then
  recorded_profile="$(shell_env_profile_from_state_or_marker "$TARGET_HOME" 2>/dev/null || true)"
  if [[ -n "$recorded_profile" ]]; then
    PROFILE="$recorded_profile"
  fi
fi
if [[ -z "$PROFILE" ]]; then
  PROFILE="desktop"
fi

case "$PROFILE" in
  desktop)
    BASHRC_SOURCE="$ASSET_DIR/bashrc.desktop"
    ZSH_SOURCE="$ASSET_DIR/zshrc.desktop"
    ;;
  server)
    BASHRC_SOURCE="$ASSET_DIR/bashrc.server"
    ZSH_SOURCE="$ASSET_DIR/zshrc.server"
    ;;
  *)
    die "Unsupported shell profile: $PROFILE"
    ;;
esac
PROFILE_SOURCE="$ASSET_DIR/profile"

if [[ "$APPLY" -ne 1 ]]; then
  cat <<EOF
This was a check run. The script would:
  1. Deploy managed profile → ${TARGET_HOME}/.profile (shared)
  2. Deploy ${PROFILE}-specific .bashrc → ${TARGET_HOME}/.bashrc (managed)
  3. Deploy ${PROFILE}-specific .zshrc → ${TARGET_HOME}/.zshrc (managed)
  4. Deploy tmux.conf → ${TARGET_HOME}/.tmux.conf (custom)
  5. Deploy starship.toml → ${TARGET_HOME}/.config/starship.toml (custom)
  6. Install or update starship in ${TARGET_HOME}/.local/bin
  7. Install or update zinit in ${TARGET_HOME}/.local/share/zinit
  8. Write shell-env state markers

Run with --apply to execute.
EOF
  exit 0
fi

ensure_command git
ensure_command curl
ensure_command install

if [[ "$(id -un)" != "$TARGET_USER" ]]; then
  ensure_sudo_session
fi

TMP_DIR="$(mktemp -d)"
chmod 755 "$TMP_DIR"

# 1-2. Deploy managed .profile and .bashrc
info "[1/8] Deploy managed .profile"
run_as_target_user "$TARGET_USER" "$TARGET_HOME" \
  install -m 644 "$PROFILE_SOURCE" "$TARGET_HOME/.profile"

info "[2/8] Deploy ${PROFILE}-specific .bashrc"
run_as_target_user "$TARGET_USER" "$TARGET_HOME" \
  install -m 644 "$BASHRC_SOURCE" "$TARGET_HOME/.bashrc"

# 3-5. Deploy custom configs
run_as_target_user "$TARGET_USER" "$TARGET_HOME" mkdir -p \
  "$TARGET_HOME/.config" \
  "$TARGET_HOME/.local/bin"

info "[3/8] Deploy ${PROFILE}-specific .zshrc"
run_as_target_user "$TARGET_USER" "$TARGET_HOME" \
  install -m 644 "$ZSH_SOURCE" "$TARGET_HOME/.zshrc"

info "[4/8] Deploy custom .tmux.conf"
run_as_target_user "$TARGET_USER" "$TARGET_HOME" \
  install -m 644 "$ASSET_DIR/tmux.conf" "$TARGET_HOME/.tmux.conf"

info "[5/8] Deploy custom starship.toml"
run_as_target_user "$TARGET_USER" "$TARGET_HOME" \
  install -m 644 "$ASSET_DIR/starship.toml" "$TARGET_HOME/.config/starship.toml"

# 6. Install or update starship
info "[6/8] Install or update starship"
script_path="$TMP_DIR/starship-install.sh"
download_url_with_speed_guard "https://starship.rs/install.sh" "$script_path"
chmod 644 "$script_path"
run_as_target_user "$TARGET_USER" "$TARGET_HOME" \
  sh "$script_path" -y -b "$TARGET_HOME/.local/bin"

# 7. Install or update zinit
info "[7/8] Install or update zinit"
zinit_dir="$TARGET_HOME/.local/share/zinit/zinit.git"
run_as_target_user "$TARGET_USER" "$TARGET_HOME" mkdir -p "$(dirname "$zinit_dir")"
if [[ -d "$zinit_dir/.git" ]]; then
  run_as_target_user "$TARGET_USER" "$TARGET_HOME" git -C "$zinit_dir" pull --ff-only
else
  run_as_target_user "$TARGET_USER" "$TARGET_HOME" \
    git clone https://github.com/zdharma-continuum/zinit "$zinit_dir"
fi

# 8. Write state markers
info "[8/8] Write shell-env state markers"
state_dir="$(linux_setup_state_dir_for_home "$TARGET_HOME")"
state_file="$(shell_env_state_file_for_home "$TARGET_HOME")"
marker_path="$(shell_env_profile_marker_for_home "$TARGET_HOME")"
timestamp="$(date +%Y-%m-%dT%H:%M:%S%:z)"

run_as_target_user "$TARGET_USER" "$TARGET_HOME" mkdir -p "$state_dir"
run_as_target_user "$TARGET_USER" "$TARGET_HOME" sh -c "printf '%s\n' '$PROFILE' > '$marker_path'"
run_as_target_user "$TARGET_USER" "$TARGET_HOME" sh -c "cat > '$state_file' <<'EOF'
SHELL_ENV_MANAGED=1
SHELL_ENV_PROFILE=$PROFILE
SHELL_ENV_LAST_APPLIED_AT=$timestamp
EOF"

info "Shell configuration deployed for $TARGET_USER (profile: $PROFILE)."
