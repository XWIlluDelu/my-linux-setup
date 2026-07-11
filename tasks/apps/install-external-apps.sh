#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"
ROOT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

CACHE_ROOT=""
DEB_CACHE_DIR=""
# Community-standard scope: user fonts stay in the managed target home directory.
ASSET_CACHE_DIR=""
FONT_DEST_DIR=""
LOCAL_APP_ROOT=""
LOCAL_BIN_DIR=""
LOCAL_APPLICATIONS_DIR=""
LOCAL_ICON_DIR=""
ZOTERO_INSTALL_DIR=""
OBSIDIAN_INSTALL_DIR=""
# Allow an explicit override, but otherwise derive the basename from the current upstream installer and only add a leading dot under $HOME.
MINIFORGE_PREFIX_OVERRIDE="${MINIFORGE_PREFIX:-}"
TARGET_USER=""
TARGET_HOME=""
TMP_DIR=""
GHOSTTY_CONFIG_ASSET="$ROOT_DIR/assets/ghostty/config"
GHOSTTY_INSTALL_STATUS=""
GHOSTTY_INSTALL_MESSAGE=""
PKG_MANAGER=""
FLATPAK_BASE_READY=0

INSTALL_FLATPAK=0
INSTALL_WECHAT=0
INSTALL_CLASH_VERGE_REV=0
INSTALL_ZOTERO=0
INSTALL_OBSIDIAN=0
INSTALL_GHOSTTY=0
INSTALL_MAPLE_FONT=0
INSTALL_MINIFORGE=0

cleanup() {
  if [[ -n "${TMP_DIR:-}" && -d "${TMP_DIR:-}" ]]; then
    rm -rf "$TMP_DIR"
  fi
}
trap cleanup EXIT

usage() {
  cat <<'EOF'
Install selected managed apps and user-space tools.

Usage:
  install-external-apps.sh [--check] [--apply]
    [--flatpak 0|1]
    [--wechat 0|1]
    [--clash-verge-rev 0|1]
    [--zotero 0|1]
    [--obsidian 0|1]
    [--ghostty 0|1]
    [--maple-font 0|1]
    [--miniforge 0|1]

Notes:
  - Default mode is --check.
  - Flatpak, Maple Font, and Miniforge are designed to work across apt, dnf, zypper, and pacman systems.
  - WeChat remains official-.deb-only.
  - Zotero, Obsidian, Clash Verge Rev, and Ghostty follow the official installation path documented by each project for the current distro when available.
EOF
}

run_flatpak_user() {
  run_as_target_user "$TARGET_USER" "$TARGET_HOME" flatpak "$@"
}

parse_bool() {
  case "$2" in
    0|1)
      printf '%s\n' "$2"
      ;;
    *)
      die "$1 requires 0 or 1"
      ;;
  esac
}

run_optional_external_step() {
  local step_id func_name
  step_id="$1"
  func_name="$2"

  if ! ( set +e; "$func_name" ); then
    warn "[${step_id}] Managed app step exited unexpectedly."
    record_result "$step_id" failed "The ${step_id} managed app step exited unexpectedly."
  fi
}

record_skip_if_not_selected() {
  local selected_flag result_id
  selected_flag="$1"
  result_id="$2"

  if [[ "$selected_flag" -eq 0 ]]; then
    record_result "$result_id" skipped_not_selected "Skipped by current selection."
  fi
}

record_disabled_results() {
  record_skip_if_not_selected "$INSTALL_FLATPAK" flatpak
  record_skip_if_not_selected "$INSTALL_WECHAT" wechat
  record_skip_if_not_selected "$INSTALL_CLASH_VERGE_REV" clash_verge_rev
  record_skip_if_not_selected "$INSTALL_ZOTERO" zotero
  record_skip_if_not_selected "$INSTALL_OBSIDIAN" obsidian
  record_skip_if_not_selected "$INSTALL_GHOSTTY" ghostty
  record_skip_if_not_selected "$INSTALL_MAPLE_FONT" maple_font
  record_skip_if_not_selected "$INSTALL_MINIFORGE" miniforge
}

detect_external_pkg_manager() {
  PKG_MANAGER="$(detect_pkg_manager 2>/dev/null || true)"
}

apt_deb_workflow_supported() {
  detect_external_pkg_manager
  supports_debian_apt_workflow "$PKG_MANAGER"
}

skip_apt_deb_workflow() {
  local result_id human_name detail
  result_id="$1"
  human_name="$2"
  detail="${3:-}"
  record_result "$result_id" skipped_unsupported "${human_name} package-managed install currently supports Debian/Ubuntu apt systems only${detail}."
}

skip_with_official_guidance() {
  local result_id human_name guidance
  result_id="$1"
  human_name="$2"
  guidance="$3"
  record_result "$result_id" skipped_unsupported "${human_name} is not automated on this distro. Official guidance: ${guidance}"
}

selected_external_steps_need_sudo() {
  [[ "$INSTALL_FLATPAK" -eq 1 || "$INSTALL_WECHAT" -eq 1 || "$INSTALL_CLASH_VERGE_REV" -eq 1 || "$INSTALL_ZOTERO" -eq 1 || "$INSTALL_OBSIDIAN" -eq 1 || "$INSTALL_GHOSTTY" -eq 1 ]]
}

installed_version_or_empty() {
  local package_name
  package_name="$1"
  dpkg-query -W -f='${Version}\n' "$package_name" 2>/dev/null || true
}

read_deb_field_or_empty() {
  local deb_path field_name
  deb_path="$1"
  field_name="$2"
  dpkg-deb -f "$deb_path" "$field_name" 2>/dev/null || true
}

read_rpm_field_or_empty() {
  local rpm_path field_name query_format
  rpm_path="$1"
  field_name="$2"

  case "$field_name" in
    Name)
      query_format='%{NAME}\n'
      ;;
    Version)
      query_format='%{VERSION}\n'
      ;;
    Release)
      query_format='%{RELEASE}\n'
      ;;
    VersionRelease)
      query_format='%{VERSION}-%{RELEASE}\n'
      ;;
    *)
      return 1
      ;;
  esac

  rpm -qp --qf "$query_format" "$rpm_path" 2>/dev/null || true
}

package_installed_for_current_manager() {
  local package_name
  package_name="$1"

  case "$PKG_MANAGER" in
    apt-get)
      dpkg_package_installed "$package_name"
      ;;
    dnf|zypper)
      command_exists rpm || return 1
      rpm -q "$package_name" >/dev/null 2>&1
      ;;
    pacman)
      command_exists pacman || return 1
      pacman -Q "$package_name" >/dev/null 2>&1
      ;;
    *)
      return 1
      ;;
  esac
}

installed_package_version_for_current_manager() {
  local package_name
  package_name="$1"

  case "$PKG_MANAGER" in
    apt-get)
      installed_version_or_empty "$package_name"
      ;;
    dnf|zypper)
      command_exists rpm || return 0
      rpm -q --qf '%{VERSION}-%{RELEASE}\n' "$package_name" 2>/dev/null || true
      ;;
    pacman)
      command_exists pacman || return 0
      pacman -Q "$package_name" 2>/dev/null | awk 'NR==1 {print $2}' || true
      ;;
    *)
      return 0
      ;;
  esac
}

install_local_rpm_package() {
  local rpm_path
  rpm_path="$1"

  case "$PKG_MANAGER" in
    dnf)
      as_root dnf install -y "$rpm_path"
      ;;
    zypper)
      as_root zypper --non-interactive install "$rpm_path"
      ;;
    *)
      return 1
      ;;
  esac
}

resolve_effective_url_or_empty() {
  local url
  url="$1"

  if command_exists curl; then
    curl -fsIL -o /dev/null -w '%{url_effective}' "$url" 2>/dev/null || true
    return 0
  fi

  if command_exists python3; then
    python3 - "$url" <<'PY' 2>/dev/null || true
import sys
import urllib.request

url = sys.argv[1]
req = urllib.request.Request(url, method="HEAD")
with urllib.request.urlopen(req, timeout=20) as resp:
    print(resp.geturl())
PY
    return 0
  fi

  return 0
}

basename_from_url() {
  local url
  url="${1%%\?*}"
  printf '%s\n' "${url##*/}"
}

ensure_target_path_owned() {
  local target_path
  target_path="$1"
  [[ -e "$target_path" ]] || return 0
  if [[ "$(id -un)" != "$TARGET_USER" ]]; then
    as_root chown -R "$TARGET_USER:$TARGET_USER" "$target_path"
  fi
}

write_text_file_as_target_user() {
  local target_path file_content
  target_path="$1"
  file_content="$2"
  run_as_target_user "$TARGET_USER" "$TARGET_HOME" sh -c 'printf "%s\n" "$1" > "$2"' sh "$file_content" "$target_path"
}

prepare_user_app_dirs() {
  run_as_target_user "$TARGET_USER" "$TARGET_HOME" mkdir -p \
    "$LOCAL_APP_ROOT" \
    "$LOCAL_BIN_DIR" \
    "$LOCAL_APPLICATIONS_DIR" \
    "$LOCAL_ICON_DIR"
}

install_symlink_as_target_user() {
  local source_path target_path
  source_path="$1"
  target_path="$2"
  run_as_target_user "$TARGET_USER" "$TARGET_HOME" sh -c '
    rm -f "$2"
    ln -s "$1" "$2"
  ' sh "$source_path" "$target_path"
}

prepare_miniforge_update_prefix() {
  local target_prefix legacy_conda_link
  target_prefix="$1"
  legacy_conda_link="$target_prefix/_conda"

  # Older Miniforge prefixes may already contain a constructor-created _conda link.
  # Newer installers recreate it during bootstrap and abort with "ln: Already exists"
  # unless we clear the legacy link first.
  if [[ -L "$legacy_conda_link" || -f "$legacy_conda_link" ]]; then
    info "[miniforge] Removing legacy _conda bootstrap link before update"
    run_as_target_user "$TARGET_USER" "$TARGET_HOME" rm -f "$legacy_conda_link"
  fi
}

# Each selectable app owns one adapter named after its component ID.
for component in "${MANAGED_APP_COMPONENTS[@]}"; do
  source "$SCRIPT_DIR/external/$component.sh"
done
unset component

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)
      APPLY=0
      ;;
    --apply)
      APPLY=1
      ;;
    --flatpak)
      [[ $# -ge 2 ]] || die "--flatpak requires a value"
      INSTALL_FLATPAK="$(parse_bool "$1" "$2")"
      shift
      ;;
    --wechat)
      [[ $# -ge 2 ]] || die "--wechat requires a value"
      INSTALL_WECHAT="$(parse_bool "$1" "$2")"
      shift
      ;;
    --clash-verge-rev)
      [[ $# -ge 2 ]] || die "--clash-verge-rev requires a value"
      INSTALL_CLASH_VERGE_REV="$(parse_bool "$1" "$2")"
      shift
      ;;
    --zotero)
      [[ $# -ge 2 ]] || die "--zotero requires a value"
      INSTALL_ZOTERO="$(parse_bool "$1" "$2")"
      shift
      ;;
    --obsidian)
      [[ $# -ge 2 ]] || die "--obsidian requires a value"
      INSTALL_OBSIDIAN="$(parse_bool "$1" "$2")"
      shift
      ;;
    --ghostty)
      [[ $# -ge 2 ]] || die "--ghostty requires a value"
      INSTALL_GHOSTTY="$(parse_bool "$1" "$2")"
      shift
      ;;
    --maple-font)
      [[ $# -ge 2 ]] || die "--maple-font requires a value"
      INSTALL_MAPLE_FONT="$(parse_bool "$1" "$2")"
      shift
      ;;
    --miniforge)
      [[ $# -ge 2 ]] || die "--miniforge requires a value"
      INSTALL_MINIFORGE="$(parse_bool "$1" "$2")"
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
CACHE_ROOT="$TARGET_HOME/.cache/linux-setup"
DEB_CACHE_DIR="$CACHE_ROOT/debs"
ASSET_CACHE_DIR="$CACHE_ROOT/assets"
FONT_DEST_DIR="$TARGET_HOME/.local/share/fonts/MapleMono-NF-CN-unhinted"
LOCAL_APP_ROOT="$TARGET_HOME/.local/opt"
LOCAL_BIN_DIR="$TARGET_HOME/.local/bin"
LOCAL_APPLICATIONS_DIR="$TARGET_HOME/.local/share/applications"
LOCAL_ICON_DIR="$TARGET_HOME/.local/share/icons/hicolor/512x512/apps"
ZOTERO_INSTALL_DIR="$LOCAL_APP_ROOT/zotero"
OBSIDIAN_INSTALL_DIR="$LOCAL_APP_ROOT/obsidian"
detect_external_pkg_manager

if [[ "$APPLY" -ne 1 ]]; then
  cat <<EOF
This was a check run. The script would:
  1. Install Flatpak, configure system+user Flathub remotes, apply Chinese settings, and install Flatseal when selected
  2. Install WeChat from the official .deb when selected
  3. Detect, download, and install Clash Verge Rev via the official package path for this distro when selected
  4. Install Zotero through zotero-deb on Debian/Ubuntu, or the official tarball elsewhere, when selected
  5. Install Obsidian from the official .deb on Debian/Ubuntu, or the official AppImage elsewhere, when selected
  6. Install Ghostty from the distro path documented by Ghostty when available, then deploy the managed Ghostty config from this repository
  7. Detect, install, and refresh Maple Mono NF CN unhinted when selected
  8. Detect, download, and install Miniforge to a hidden home prefix derived from the upstream default when selected

Current selection:
  - flatpak=$INSTALL_FLATPAK
  - wechat=$INSTALL_WECHAT
  - clash_verge_rev=$INSTALL_CLASH_VERGE_REV
  - zotero=$INSTALL_ZOTERO
  - obsidian=$INSTALL_OBSIDIAN
  - ghostty=$INSTALL_GHOSTTY
  - maple_font=$INSTALL_MAPLE_FONT
  - miniforge=$INSTALL_MINIFORGE

Run with --apply to execute.
EOF
  exit 0
fi

ensure_command curl
ensure_command install
ARCH="$(linux_setup_package_arch)"

if [[ "$(id -un)" != "$TARGET_USER" ]]; then
  ensure_sudo_session
fi

if selected_external_steps_need_sudo; then
  ensure_command sudo
  ensure_sudo_session
fi
mkdir -p "$DEB_CACHE_DIR" "$ASSET_CACHE_DIR"

record_disabled_results

run_optional_external_step flatpak install_flatpak_stack
run_optional_external_step wechat install_wechat
run_optional_external_step clash_verge_rev install_clash_verge_rev
run_optional_external_step zotero install_zotero
run_optional_external_step obsidian install_obsidian
run_optional_external_step ghostty install_ghostty
run_optional_external_step maple_font install_maple_font
run_optional_external_step miniforge install_miniforge
