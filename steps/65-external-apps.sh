#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

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
Install selected externally managed software.

Usage:
  65-external-apps.sh [--check] [--apply]
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
    warn "[${step_id}] Optional external step exited unexpectedly."
    record_stage2_result "$step_id" failed "The ${step_id} external step exited unexpectedly."
  fi
}

record_skip_if_not_selected() {
  local selected_flag result_id
  selected_flag="$1"
  result_id="$2"

  if [[ "$selected_flag" -eq 0 ]]; then
    record_stage2_result "$result_id" skipped_not_selected "Skipped by current selection."
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
  record_stage2_result "$result_id" skipped_unsupported "${human_name} package-managed install currently supports Debian/Ubuntu apt systems only${detail}."
}

skip_with_official_guidance() {
  local result_id human_name guidance
  result_id="$1"
  human_name="$2"
  guidance="$3"
  record_stage2_result "$result_id" skipped_unsupported "${human_name} is not automated on this distro. Official guidance: ${guidance}"
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

flatpak_user_app_installed() {
  run_flatpak_user info --user "$1" >/dev/null 2>&1
}

ensure_flatpak_base_ready() {
  if [[ "$FLATPAK_BASE_READY" -eq 1 ]]; then
    return 0
  fi

  info "[flatpak] Ensure Flatpak is installed and configured"
  if ! install_packages flatpak; then
    return 1
  fi

  if ! command_exists flatpak; then
    return 1
  fi

  if ! as_root flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo; then
    return 1
  fi
  if ! run_flatpak_user remote-add --user --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo; then
    return 1
  fi
  if ! as_root flatpak config --system --set extra-languages "zh;zh_CN"; then
    return 1
  fi
  if ! run_flatpak_user config --user --set extra-languages "zh;zh_CN"; then
    return 1
  fi
  if ! run_flatpak_user override --user --filesystem=xdg-config/fontconfig:ro; then
    return 1
  fi
  if ! run_flatpak_user override --user \
    --env=GTK_IM_MODULE=fcitx \
    --env=QT_IM_MODULE=fcitx \
    --env=XMODIFIERS=@im=fcitx; then
    return 1
  fi
  if ! as_root flatpak update -y; then
    return 1
  fi
  if ! run_flatpak_user update --user -y; then
    return 1
  fi

  FLATPAK_BASE_READY=1
  return 0
}

install_flatpak_stack() {
  local flatpak_pkg_installed=0 flatseal_installed=0 status

  if [[ "$INSTALL_FLATPAK" -eq 0 ]]; then
    return 0
  fi

  if command_exists flatpak; then
    flatpak_pkg_installed=1
  fi

  if flatpak_user_app_installed com.github.tchx84.Flatseal; then
    flatseal_installed=1
  fi

  if ! ensure_flatpak_base_ready; then
    record_stage2_result flatpak failed "Failed to install or configure the Flatpak base workflow."
    return 0
  fi

  if ! run_flatpak_user install --user -y flathub com.github.tchx84.Flatseal; then
    record_stage2_result flatpak failed "Flatpak was configured, but Flatseal failed to install."
    return 0
  fi

  if [[ "$flatpak_pkg_installed" -eq 1 && "$flatseal_installed" -eq 1 ]]; then
    status="updated"
  else
    status="installed"
  fi
  record_stage2_result flatpak "$status" "Configured Flatpak (system and user Flathub remotes), Chinese settings, input method overrides, and Flatseal."
}

install_wechat_official_deb() {
  local deb_path package_name package_version installed_before=0 status
  local installed_version

  # Official .deb packages integrate with the system package database, so this stays system-wide.
  if [[ "$ARCH" != "amd64" ]]; then
    record_stage2_result wechat skipped_unsupported "Official WeChat .deb is only supported on amd64."
    return 0
  fi

  if ! apt_deb_workflow_supported; then
    skip_apt_deb_workflow wechat "WeChat"
    return 0
  fi

  deb_path="$DEB_CACHE_DIR/WeChatLinux_x86_64.deb"

  if ! download_url_with_speed_guard \
    "https://dldir1v6.qq.com/weixin/Universal/Linux/WeChatLinux_x86_64.deb" \
    "$deb_path"; then
    record_stage2_result wechat failed "Failed to download the official WeChat .deb."
    return 0
  fi

  ensure_command dpkg-deb
  package_name="$(read_deb_field_or_empty "$deb_path" Package)"
  package_version="$(read_deb_field_or_empty "$deb_path" Version)"
  if [[ -z "$package_name" || -z "$package_version" ]]; then
    record_stage2_result wechat failed "Downloaded WeChat package is not a valid .deb or is missing Package/Version metadata."
    return 0
  fi
  installed_version="$(installed_version_or_empty "$package_name")"

  if [[ -n "$installed_version" && "$installed_version" == "$package_version" ]]; then
    record_stage2_result wechat already_present "Official WeChat .deb ${package_version} is already installed."
    return 0
  fi

  if [[ -n "$installed_version" ]]; then
    installed_before=1
  fi

  if apt_noninteractive install -y "$deb_path"; then
    if [[ "$installed_before" -eq 1 ]]; then
      status="updated"
    else
      status="installed"
    fi
    record_stage2_result wechat "$status" "Installed official WeChat .deb ${package_version}."
  else
    record_stage2_result wechat failed "Failed to install the official WeChat .deb."
  fi
}

install_wechat() {
  if [[ "$INSTALL_WECHAT" -eq 0 ]]; then
    return 0
  fi

  install_wechat_official_deb
}

install_github_release_deb() {
  local result_id repo asset_regex package_name tag_prefix human_name
  local installed_before=0 status target_path installed_version deb_package deb_version

  # These are still .deb installs, so they intentionally remain system-wide.
  result_id="$1"
  repo="$2"
  asset_regex="$3"
  package_name="$4"
  tag_prefix="$5"
  human_name="$6"

  if ! apt_deb_workflow_supported; then
    skip_apt_deb_workflow "$result_id" "$human_name"
    return 0
  fi

  if ! github_release_parse_latest "$repo" "$asset_regex" "$tag_prefix"; then
    record_stage2_result "$result_id" failed "Failed to detect the latest ${human_name} release."
    return 0
  fi

  installed_version="$(installed_version_or_empty "$package_name")"
  if [[ -n "$installed_version" && "$installed_version" == "$GITHUB_RELEASE_VERSION" ]]; then
    record_stage2_result "$result_id" already_present "${human_name} ${installed_version} already matches the latest release ${GITHUB_RELEASE_TAG}."
    return 0
  fi

  if [[ -n "$installed_version" ]]; then
    installed_before=1
  fi

  target_path="$DEB_CACHE_DIR/$GITHUB_ASSET_NAME"
  if ! github_release_download_asset "$GITHUB_ASSET_URL" "$GITHUB_ASSET_DIGEST" "$target_path"; then
    record_stage2_result "$result_id" failed "Failed to download ${human_name} ${GITHUB_RELEASE_TAG}."
    return 0
  fi

  ensure_command dpkg-deb
  deb_package="$(read_deb_field_or_empty "$target_path" Package)"
  deb_version="$(read_deb_field_or_empty "$target_path" Version)"
  if [[ -z "$deb_package" || -z "$deb_version" ]]; then
    record_stage2_result "$result_id" failed "${human_name} download is not a valid .deb or is missing Package/Version metadata."
    return 0
  fi
  if [[ "$deb_package" != "$package_name" ]]; then
    warn "${human_name} asset package name mismatch: expected ${package_name}, got ${deb_package}"
  fi

  if apt_noninteractive install -y "$target_path"; then
    if [[ "$installed_before" -eq 1 ]]; then
      status="updated"
    else
      status="installed"
    fi
    record_stage2_result "$result_id" "$status" "Installed ${human_name} ${deb_version} from ${GITHUB_RELEASE_TAG}."
  else
    record_stage2_result "$result_id" failed "Failed to install ${human_name} from ${GITHUB_ASSET_NAME}."
  fi
}

clash_verge_rpm_arch() {
  case "$ARCH" in
    amd64)
      printf 'x86_64\n'
      ;;
    arm64)
      printf 'aarch64\n'
      ;;
    armhf)
      printf 'armhfp\n'
      ;;
    *)
      return 1
      ;;
  esac
}

install_clash_verge_rev_rpm() {
  local asset_regex installed_before=0 status
  local target_path rpm_package rpm_version installed_version rpm_arch

  if ! rpm_arch="$(clash_verge_rpm_arch)"; then
    record_stage2_result clash_verge_rev skipped_unsupported "Official Clash Verge Rev rpm assets are not published for architecture ${ARCH}."
    record_stage2_result clash_verge_rev_service skipped_unsupported "Clash Verge Rev service mode is unavailable because no supported rpm asset exists for ${ARCH}."
    return 0
  fi

  asset_regex="Clash\\.Verge-.*-1\\.${rpm_arch}\\.rpm$"
  if ! github_release_parse_latest \
    clash-verge-rev/clash-verge-rev \
    "$asset_regex" \
    "v"; then
    record_stage2_result clash_verge_rev failed "Failed to detect the latest Clash Verge Rev rpm release."
    record_stage2_result clash_verge_rev_service skipped_unavailable "Clash Verge Rev service mode was not attempted because the rpm release metadata could not be resolved."
    return 0
  fi

  target_path="$ASSET_CACHE_DIR/$GITHUB_ASSET_NAME"
  if ! github_release_download_asset "$GITHUB_ASSET_URL" "$GITHUB_ASSET_DIGEST" "$target_path"; then
    record_stage2_result clash_verge_rev failed "Failed to download Clash Verge Rev ${GITHUB_RELEASE_TAG}."
    record_stage2_result clash_verge_rev_service skipped_unavailable "Clash Verge Rev service mode was not attempted because the rpm asset failed to download."
    return 0
  fi

  ensure_command rpm
  rpm_package="$(read_rpm_field_or_empty "$target_path" Name)"
  rpm_version="$(read_rpm_field_or_empty "$target_path" VersionRelease)"
  if [[ -z "$rpm_package" || -z "$rpm_version" ]]; then
    record_stage2_result clash_verge_rev failed "Downloaded Clash Verge Rev rpm is invalid or missing Name/Version metadata."
    record_stage2_result clash_verge_rev_service skipped_unavailable "Clash Verge Rev service mode was not attempted because the rpm metadata could not be read."
    return 0
  fi

  installed_version="$(installed_package_version_for_current_manager "$rpm_package")"
  if [[ -n "$installed_version" && "$installed_version" == "$rpm_version" ]]; then
    record_stage2_result clash_verge_rev already_present "Clash Verge Rev ${rpm_version} already matches the latest rpm release ${GITHUB_RELEASE_TAG}."
  else
    if [[ -n "$installed_version" ]]; then
      installed_before=1
    fi

    if install_local_rpm_package "$target_path"; then
      if [[ "$installed_before" -eq 1 ]]; then
        status="updated"
      else
        status="installed"
      fi
      record_stage2_result clash_verge_rev "$status" "Installed Clash Verge Rev ${rpm_version} from ${GITHUB_RELEASE_TAG}."
    else
      record_stage2_result clash_verge_rev failed "Failed to install Clash Verge Rev from ${GITHUB_ASSET_NAME}."
    fi
  fi

  if command_exists clash-verge-service-install; then
    info "Installing Clash Verge Rev service mode (required for TUN)..."
    if as_root clash-verge-service-install; then
      info "Clash Verge Rev service mode installed successfully."
      record_stage2_result clash_verge_rev_service configured "Installed Clash Verge Rev service mode for TUN."
    else
      warn "Failed to install Clash Verge Rev service mode. TUN will not work until service mode is installed manually."
      record_stage2_result clash_verge_rev_service failed "Failed to install Clash Verge Rev service mode for TUN."
    fi
  else
    record_stage2_result clash_verge_rev_service skipped_unavailable "Clash Verge Rev service installer was not available after rpm installation."
  fi
}

ensure_yay_available() {
  local build_dir

  if command_exists yay; then
    return 0
  fi

  info "[clash_verge_rev] Installing yay from the official AUR workflow"
  if ! install_packages base-devel git; then
    return 1
  fi

  build_dir="$TARGET_HOME/.cache/linux-setup/yay-build"
  run_as_target_user "$TARGET_USER" "$TARGET_HOME" rm -rf "$build_dir"
  if ! run_as_target_user "$TARGET_USER" "$TARGET_HOME" mkdir -p "$build_dir"; then
    return 1
  fi

  if ! run_as_target_user "$TARGET_USER" "$TARGET_HOME" git clone https://aur.archlinux.org/yay.git "$build_dir/yay"; then
    run_as_target_user "$TARGET_USER" "$TARGET_HOME" rm -rf "$build_dir" || true
    return 1
  fi

  if ! run_as_target_user "$TARGET_USER" "$TARGET_HOME" sh -c '
    cd "$1"
    makepkg -si --noconfirm
  ' sh "$build_dir/yay"; then
    run_as_target_user "$TARGET_USER" "$TARGET_HOME" rm -rf "$build_dir" || true
    return 1
  fi

  run_as_target_user "$TARGET_USER" "$TARGET_HOME" rm -rf "$build_dir" || true
}

install_clash_verge_rev_arch() {
  local package_name installed_before=0 status
  local installed_version final_version
  package_name="clash-verge-rev-bin"

  if ! ensure_yay_available; then
    record_stage2_result clash_verge_rev failed "Failed to bootstrap yay for the official Arch Linux installation path."
    record_stage2_result clash_verge_rev_service skipped_unavailable "Clash Verge Rev service mode was not attempted because yay setup failed."
    return 0
  fi

  installed_version="$(installed_package_version_for_current_manager "$package_name")"
  if [[ -n "$installed_version" ]]; then
    installed_before=1
  fi

  if ! run_as_target_user "$TARGET_USER" "$TARGET_HOME" yay -S --noconfirm --needed "$package_name"; then
    record_stage2_result clash_verge_rev failed "Failed to install Clash Verge Rev via the official Arch Linux yay workflow."
    record_stage2_result clash_verge_rev_service skipped_unavailable "Clash Verge Rev service mode was not attempted because the Arch package install failed."
    return 0
  fi

  final_version="$(installed_package_version_for_current_manager "$package_name")"
  if [[ -z "$final_version" ]]; then
    record_stage2_result clash_verge_rev failed "Clash Verge Rev Arch package install completed, but the package is not queryable afterward."
  elif [[ "$installed_before" -eq 1 && "$installed_version" == "$final_version" ]]; then
    record_stage2_result clash_verge_rev already_present "Clash Verge Rev ${final_version} is already installed from the official Arch Linux package path."
  elif [[ "$installed_before" -eq 1 ]]; then
    record_stage2_result clash_verge_rev updated "Updated Clash Verge Rev to ${final_version} via the official Arch Linux package path."
  else
    status="installed"
    record_stage2_result clash_verge_rev "$status" "Installed Clash Verge Rev ${final_version} via the official Arch Linux package path."
  fi

  if command_exists clash-verge-service-install; then
    info "Installing Clash Verge Rev service mode (required for TUN)..."
    if as_root clash-verge-service-install; then
      info "Clash Verge Rev service mode installed successfully."
      record_stage2_result clash_verge_rev_service configured "Installed Clash Verge Rev service mode for TUN."
    else
      warn "Failed to install Clash Verge Rev service mode. TUN will not work until service mode is installed manually."
      record_stage2_result clash_verge_rev_service failed "Failed to install Clash Verge Rev service mode for TUN."
    fi
  else
    record_stage2_result clash_verge_rev_service skipped_unavailable "Clash Verge Rev service installer was not available after Arch package installation."
  fi
}

install_clash_verge_rev() {
  if [[ "$INSTALL_CLASH_VERGE_REV" -eq 0 ]]; then
    return 0
  fi

  if apt_deb_workflow_supported; then
    install_github_release_deb \
      clash_verge_rev \
      clash-verge-rev/clash-verge-rev \
      "Clash\\.Verge_.*_${ARCH}\\.deb$" \
      clash-verge \
      "v" \
      "Clash Verge Rev"

    if command_exists clash-verge-service-install; then
      info "Installing Clash Verge Rev service mode (required for TUN)..."
      if as_root clash-verge-service-install; then
        info "Clash Verge Rev service mode installed successfully."
        record_stage2_result clash_verge_rev_service configured "Installed Clash Verge Rev service mode for TUN."
      else
        warn "Failed to install Clash Verge Rev service mode. TUN will not work until service mode is installed manually."
        record_stage2_result clash_verge_rev_service failed "Failed to install Clash Verge Rev service mode for TUN."
      fi
    else
      record_stage2_result clash_verge_rev_service skipped_unavailable "Clash Verge Rev service installer was not available after package installation."
    fi
    return 0
  fi

  case "$PKG_MANAGER" in
    dnf|zypper)
      install_clash_verge_rev_rpm
      ;;
    pacman)
      install_clash_verge_rev_arch
      ;;
    *)
      skip_with_official_guidance \
        clash_verge_rev \
        "Clash Verge Rev" \
        "the official docs publish .deb, .rpm, and Arch yay/AUR paths only."
      record_stage2_result clash_verge_rev_service skipped_unsupported "Clash Verge Rev service mode is only automated for the official package paths."
      ;;
  esac
}

zotero_download_url_for_arch() {
  case "$ARCH" in
    amd64)
      printf 'https://www.zotero.org/download/client/dl?channel=release&platform=linux-x86_64\n'
      ;;
    arm64)
      printf 'https://www.zotero.org/download/client/dl?channel=release&platform=linux-arm64\n'
      ;;
    *)
      return 1
      ;;
  esac
}

zotero_installed_version_or_empty() {
  local application_ini
  application_ini="$ZOTERO_INSTALL_DIR/application.ini"
  [[ -r "$application_ini" ]] || return 0

  awk -F= '
    /^\[App\]/ { in_app=1; next }
    /^\[/ { in_app=0 }
    in_app && $1 == "Version" { print $2; exit }
  ' "$application_ini"
}

install_zotero_tarball() {
  local download_url final_url release_version asset_name target_path
  local installed_version status work_dir extract_dir extracted_root staged_dir

  if ! download_url="$(zotero_download_url_for_arch)"; then
    record_stage2_result zotero skipped_unsupported "Official Zotero tarballs are not published for architecture ${ARCH}."
    return 0
  fi

  final_url="$(resolve_effective_url_or_empty "$download_url")"
  if [[ -z "$final_url" ]]; then
    record_stage2_result zotero failed "Failed to resolve the official Zotero download URL."
    return 0
  fi

  release_version="$(sed -n 's#.*/release/\([^/]*\)/.*#\1#p' <<<"$final_url" | head -n 1)"
  if [[ -z "$release_version" ]]; then
    record_stage2_result zotero failed "Failed to determine the Zotero release version from the official download URL."
    return 0
  fi

  installed_version="$(zotero_installed_version_or_empty)"
  if [[ -n "$installed_version" && "$installed_version" == "$release_version" ]]; then
    record_stage2_result zotero already_present "Official Zotero tarball ${release_version} is already installed."
    return 0
  fi

  asset_name="$(basename_from_url "$final_url")"
  target_path="$ASSET_CACHE_DIR/$asset_name"
  if ! download_url_with_speed_guard "$download_url" "$target_path"; then
    record_stage2_result zotero failed "Failed to download the official Zotero tarball."
    return 0
  fi

  work_dir="$(mktemp -d)"
  extract_dir="$work_dir/extract"
  mkdir -p "$extract_dir"

  if ! tar -xf "$target_path" -C "$extract_dir"; then
    rm -rf "$work_dir"
    record_stage2_result zotero failed "Failed to unpack the official Zotero tarball."
    return 0
  fi

  extracted_root="$(find "$extract_dir" -mindepth 1 -maxdepth 1 -type d | head -n 1 || true)"
  if [[ -z "$extracted_root" || ! -x "$extracted_root/zotero" ]]; then
    rm -rf "$work_dir"
    record_stage2_result zotero failed "The official Zotero tarball was unpacked, but the Zotero launcher was not found."
    return 0
  fi

  staged_dir="$work_dir/zotero"
  mv "$extracted_root" "$staged_dir"

  prepare_user_app_dirs
  run_as_target_user "$TARGET_USER" "$TARGET_HOME" mkdir -p "$LOCAL_APP_ROOT"
  if [[ -d "$ZOTERO_INSTALL_DIR" ]]; then
    rm -rf "$ZOTERO_INSTALL_DIR"
  fi
  mv "$staged_dir" "$ZOTERO_INSTALL_DIR"
  ensure_target_path_owned "$ZOTERO_INSTALL_DIR"

  if [[ -x "$ZOTERO_INSTALL_DIR/set_launcher_icon" ]]; then
    run_as_target_user "$TARGET_USER" "$TARGET_HOME" sh -c '
      cd "$1"
      ./set_launcher_icon
    ' sh "$ZOTERO_INSTALL_DIR"
  fi

  if [[ -f "$ZOTERO_INSTALL_DIR/zotero.desktop" ]]; then
    install_symlink_as_target_user "$ZOTERO_INSTALL_DIR/zotero.desktop" "$LOCAL_APPLICATIONS_DIR/zotero.desktop"
  fi
  install_symlink_as_target_user "$ZOTERO_INSTALL_DIR/zotero" "$LOCAL_BIN_DIR/zotero"

  rm -rf "$work_dir"
  if [[ -n "$installed_version" ]]; then
    status="updated"
  else
    status="installed"
  fi
  record_stage2_result zotero "$status" "Installed Zotero ${release_version} from the official tarball and linked it into the user desktop/app path."
}

install_zotero() {
  local installer_path installed_before=0 status

  if [[ "$INSTALL_ZOTERO" -eq 0 ]]; then
    return 0
  fi

  if ! apt_deb_workflow_supported; then
    install_zotero_tarball
    return 0
  fi

  installer_path="$ASSET_CACHE_DIR/zotero-deb-install.sh"
  if dpkg_package_installed zotero; then
    installed_before=1
  fi

  if ! download_url_with_speed_guard \
    "https://raw.githubusercontent.com/retorquere/zotero-deb/master/install.sh" \
    "$installer_path"; then
    record_stage2_result zotero failed "Failed to download the third-party Zotero installer script."
    return 0
  fi

  if ! as_root bash "$installer_path"; then
    record_stage2_result zotero failed "Failed to run the third-party Zotero installer script."
    return 0
  fi

  if ! apt_noninteractive update; then
    record_stage2_result zotero failed "Failed to refresh package metadata after the Zotero third-party repo install."
    return 0
  fi

  if apt_noninteractive install -y zotero; then
    if [[ "$installed_before" -eq 1 ]]; then
      status="updated"
    else
      status="installed"
    fi
    record_stage2_result zotero "$status" "Installed Zotero via the retorquere third-party repo path."
  else
    record_stage2_result zotero failed "Failed to install Zotero from the retorquere third-party repo."
  fi
}

resolve_obsidian_download_from_official_page() {
  local artifact_kind html pattern
  artifact_kind="$1"

  if ! html="$(curl -fsSL -A 'Mozilla/5.0' https://obsidian.md/download)"; then
    return 1
  fi

  case "$artifact_kind" in
    deb-amd64)
      pattern='https://github.com/obsidianmd/obsidian-releases/releases/download/v[0-9.]+/obsidian_[0-9.]+_amd64\.deb'
      ;;
    appimage-amd64)
      pattern='https://github.com/obsidianmd/obsidian-releases/releases/download/v[0-9.]+/Obsidian-[0-9.]+\.AppImage'
      ;;
    appimage-arm64)
      pattern='https://github.com/obsidianmd/obsidian-releases/releases/download/v[0-9.]+/Obsidian-[0-9.]+-arm64\.AppImage'
      ;;
    *)
      return 1
      ;;
  esac

  grep -Eo "$pattern" <<<"$html" | head -n 1 || true
}

extract_appimage_icon_if_possible() {
  local appimage_path icon_target
  appimage_path="$1"
  icon_target="$2"

  run_as_target_user "$TARGET_USER" "$TARGET_HOME" sh -c '
    tmpdir="$(mktemp -d)"
    trap "rm -rf \"$tmpdir\"" EXIT
    cd "$tmpdir"
    if "$1" --appimage-extract .DirIcon >/dev/null 2>&1 && [ -f squashfs-root/.DirIcon ]; then
      mkdir -p "$(dirname "$2")"
      install -m 644 squashfs-root/.DirIcon "$2"
    fi
  ' sh "$appimage_path" "$icon_target" || true
}

install_obsidian_appimage() {
  local official_url release_version asset_name target_path
  local install_dir appimage_target wrapper_path icon_target desktop_path
  local existing_release_tag status desktop_entry

  case "$ARCH" in
    amd64)
      official_url="$(resolve_obsidian_download_from_official_page appimage-amd64)"
      ;;
    arm64)
      official_url="$(resolve_obsidian_download_from_official_page appimage-arm64)"
      ;;
    *)
      official_url=""
      ;;
  esac

  if [[ -z "$official_url" ]]; then
    record_stage2_result obsidian skipped_unsupported "Official Obsidian AppImages are not published for architecture ${ARCH}, or the official download page could not be parsed."
    return 0
  fi

  release_version="$(sed -n 's#.*/Obsidian-\([0-9.]*\)\(-arm64\)\?\.AppImage#\1#p' <<<"$official_url" | head -n 1)"
  asset_name="$(basename_from_url "$official_url")"

  install_dir="$OBSIDIAN_INSTALL_DIR"
  appimage_target="$install_dir/Obsidian.AppImage"
  wrapper_path="$LOCAL_BIN_DIR/obsidian"
  icon_target="$LOCAL_ICON_DIR/obsidian.png"
  desktop_path="$LOCAL_APPLICATIONS_DIR/obsidian.desktop"

  existing_release_tag=""
  if [[ -f "$install_dir/.release-tag" ]]; then
    existing_release_tag="$(<"$install_dir/.release-tag")"
  fi
  if [[ -n "$existing_release_tag" && "$existing_release_tag" == "$release_version" && -x "$appimage_target" ]]; then
    record_stage2_result obsidian already_present "Official Obsidian AppImage ${release_version} is already installed."
    return 0
  fi

  target_path="$ASSET_CACHE_DIR/$asset_name"
  if ! download_url_with_speed_guard "$official_url" "$target_path"; then
    record_stage2_result obsidian failed "Failed to download the official Obsidian AppImage ${release_version}."
    return 0
  fi

  prepare_user_app_dirs
  run_as_target_user "$TARGET_USER" "$TARGET_HOME" mkdir -p "$install_dir"
  run_as_target_user "$TARGET_USER" "$TARGET_HOME" install -m 755 "$target_path" "$appimage_target"
  extract_appimage_icon_if_possible "$appimage_target" "$icon_target"

  write_text_file_as_target_user "$wrapper_path" "#!/usr/bin/env sh
exec \"$appimage_target\" \"\$@\""
  run_as_target_user "$TARGET_USER" "$TARGET_HOME" chmod 755 "$wrapper_path"

  desktop_entry="[Desktop Entry]
Name=Obsidian
Exec=$appimage_target %U
TryExec=$appimage_target
Terminal=false
Type=Application
Icon=$icon_target
StartupWMClass=obsidian
Comment=Knowledge base powered by Markdown
MimeType=x-scheme-handler/obsidian;
Categories=Office;"
  write_text_file_as_target_user "$desktop_path" "$desktop_entry"
  run_as_target_user "$TARGET_USER" "$TARGET_HOME" chmod 644 "$desktop_path"
  write_text_file_as_target_user "$install_dir/.release-tag" "$release_version"
  write_text_file_as_target_user "$install_dir/.asset-name" "$asset_name"
  write_text_file_as_target_user "$install_dir/.source-url" "$official_url"
  ensure_target_path_owned "$install_dir"

  if [[ -n "$existing_release_tag" ]]; then
    status="updated"
  else
    status="installed"
  fi
  record_stage2_result obsidian "$status" "Installed Obsidian ${release_version} from the official AppImage and integrated it into the user desktop/app path."
}

install_obsidian_official_deb() {
  local official_url target_path installed_before=0 status
  local deb_package deb_version installed_version

  official_url="$(resolve_obsidian_download_from_official_page deb-amd64)"
  if [[ -z "$official_url" ]]; then
    record_stage2_result obsidian failed "Failed to resolve the official Obsidian .deb download URL from the download page."
    return 0
  fi

  target_path="$DEB_CACHE_DIR/$(basename_from_url "$official_url")"
  if ! download_url_with_speed_guard "$official_url" "$target_path"; then
    record_stage2_result obsidian failed "Failed to download the official Obsidian .deb."
    return 0
  fi

  ensure_command dpkg-deb
  deb_package="$(read_deb_field_or_empty "$target_path" Package)"
  deb_version="$(read_deb_field_or_empty "$target_path" Version)"
  if [[ -z "$deb_package" || -z "$deb_version" ]]; then
    record_stage2_result obsidian failed "Downloaded Obsidian package is not a valid .deb or is missing Package/Version metadata."
    return 0
  fi

  installed_version="$(installed_version_or_empty "$deb_package")"
  if [[ -n "$installed_version" && "$installed_version" == "$deb_version" ]]; then
    record_stage2_result obsidian already_present "Official Obsidian .deb ${deb_version} is already installed."
    return 0
  fi

  if [[ -n "$installed_version" ]]; then
    installed_before=1
  fi

  if apt_noninteractive install -y "$target_path"; then
    if [[ "$installed_before" -eq 1 ]]; then
      status="updated"
    else
      status="installed"
    fi
    record_stage2_result obsidian "$status" "Installed Obsidian ${deb_version} from the official download page."
  else
    record_stage2_result obsidian failed "Failed to install Obsidian from the official .deb package."
  fi
}

install_obsidian() {
  if [[ "$INSTALL_OBSIDIAN" -eq 0 ]]; then
    return 0
  fi

  if ! apt_deb_workflow_supported; then
    install_obsidian_appimage
    return 0
  fi

  if [[ "$ARCH" != "amd64" ]]; then
    record_stage2_result obsidian skipped_unsupported "The official Obsidian .deb workflow is only implemented for amd64; use the AppImage path on other architectures."
    return 0
  fi

  install_obsidian_official_deb
}

deploy_managed_ghostty_config() {
  local config_dir target_config
  [[ -r "$GHOSTTY_CONFIG_ASSET" ]] || return 1

  config_dir="$TARGET_HOME/.config/ghostty"
  target_config="$config_dir/config"

  run_as_target_user "$TARGET_USER" "$TARGET_HOME" mkdir -p "$config_dir"
  run_as_target_user "$TARGET_USER" "$TARGET_HOME" install -m 644 "$GHOSTTY_CONFIG_ASSET" "$target_config"
}

ghostty_release_selector() {
  local distro_id version_id codename
  local normalized_version
  distro_id="${DISTRO_ID:-unknown}"
  version_id=""
  codename=""

  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    version_id="${VERSION_ID:-}"
    codename="${VERSION_CODENAME:-}"
  fi

  case "$distro_id" in
    debian)
      if [[ -z "$codename" ]]; then
        return 1
      fi
      printf 'debian\t%s\n' "$codename"
      ;;
    ubuntu)
      if [[ -z "$version_id" ]]; then
        return 1
      fi
      normalized_version="${version_id//./\\.}"
      printf 'ubuntu\t%s\n' "$normalized_version"
      ;;
    *)
      return 1
      ;;
  esac
}

install_ghostty_from_release() {
  local repo asset_regex source_label
  local target_path package_name package_version installed_version installed_before=0 status
  repo="$1"
  asset_regex="$2"
  source_label="$3"
  GHOSTTY_INSTALL_STATUS=""
  GHOSTTY_INSTALL_MESSAGE=""

  if ! github_release_parse_latest "$repo" "$asset_regex" ""; then
    return 1
  fi

  target_path="$DEB_CACHE_DIR/$GITHUB_ASSET_NAME"
  if ! github_release_download_asset "$GITHUB_ASSET_URL" "$GITHUB_ASSET_DIGEST" "$target_path"; then
    return 1
  fi

  ensure_command dpkg-deb
  package_name="$(dpkg-deb -f "$target_path" Package 2>/dev/null || true)"
  package_version="$(dpkg-deb -f "$target_path" Version 2>/dev/null || true)"

  if [[ -z "$package_name" ]]; then
    package_name="ghostty"
  fi
  installed_version="$(installed_version_or_empty "$package_name")"

  if [[ -n "$installed_version" && -n "$package_version" && "$installed_version" == "$package_version" ]]; then
    GHOSTTY_INSTALL_STATUS="already_present"
    GHOSTTY_INSTALL_MESSAGE="Ghostty ${package_version} already installed (${source_label})"
    return 0
  fi

  if [[ -n "$installed_version" ]]; then
    installed_before=1
  fi

  if apt_noninteractive install -y "$target_path"; then
    if [[ "$installed_before" -eq 1 ]]; then
      status="updated"
    else
      status="installed"
    fi
    if [[ -z "$package_version" ]]; then
      package_version="${GITHUB_RELEASE_TAG}"
    fi
    GHOSTTY_INSTALL_STATUS="$status"
    GHOSTTY_INSTALL_MESSAGE="Installed Ghostty ${package_version} from ${source_label}"
    return 0
  fi

  return 1
}

ensure_fedora_ghostty_repo() {
  if [[ "$PKG_MANAGER" != "dnf" ]]; then
    return 1
  fi

  if ! install_packages dnf-plugins-core; then
    return 1
  fi

  as_root dnf copr enable -y scottames/ghostty
}

install_ghostty_via_system_package() {
  local source_label package_name installed_version final_version status
  source_label="$1"
  package_name="ghostty"

  installed_version="$(installed_package_version_for_current_manager "$package_name")"
  if ! install_packages "$package_name"; then
    return 1
  fi

  final_version="$(installed_package_version_for_current_manager "$package_name")"
  if [[ -z "$final_version" ]]; then
    return 1
  fi

  if [[ -n "$installed_version" && "$installed_version" == "$final_version" ]]; then
    GHOSTTY_INSTALL_STATUS="already_present"
    GHOSTTY_INSTALL_MESSAGE="Ghostty ${final_version} already installed (${source_label})"
  elif [[ -n "$installed_version" ]]; then
    status="updated"
    GHOSTTY_INSTALL_STATUS="$status"
    GHOSTTY_INSTALL_MESSAGE="Updated Ghostty to ${final_version} via ${source_label}"
  else
    status="installed"
    GHOSTTY_INSTALL_STATUS="$status"
    GHOSTTY_INSTALL_MESSAGE="Installed Ghostty ${final_version} via ${source_label}"
  fi
}

install_ghostty() {
  local selector_kind selector_value
  local debian_regex ubuntu_regex

  if [[ "$INSTALL_GHOSTTY" -eq 0 ]]; then
    return 0
  fi

  detect_os_release

  case "$PKG_MANAGER" in
    pacman)
      if install_ghostty_via_system_package "the official Arch Linux package repository"; then
        if deploy_managed_ghostty_config; then
          record_stage2_result ghostty "$GHOSTTY_INSTALL_STATUS" "${GHOSTTY_INSTALL_MESSAGE}; deployed the managed Ghostty config."
        else
          record_stage2_result ghostty failed "${GHOSTTY_INSTALL_MESSAGE}; failed to deploy the managed Ghostty config."
        fi
        return 0
      fi
      record_stage2_result ghostty failed "Failed to install Ghostty from the official Arch Linux package repository."
      return 0
      ;;
    dnf)
      if [[ "${DISTRO_ID:-unknown}" != "fedora" ]]; then
        skip_with_official_guidance \
          ghostty \
          "Ghostty" \
          "the Ghostty docs document Fedora's COPR path, while other dnf-based distros should use a distro-maintained package or build from source."
        return 0
      fi
      if ! ensure_fedora_ghostty_repo; then
        record_stage2_result ghostty failed "Failed to enable the official-doc Fedora COPR for Ghostty."
        return 0
      fi
      if install_ghostty_via_system_package "the Fedora COPR path documented by Ghostty"; then
        if deploy_managed_ghostty_config; then
          record_stage2_result ghostty "$GHOSTTY_INSTALL_STATUS" "${GHOSTTY_INSTALL_MESSAGE}; deployed the managed Ghostty config."
        else
          record_stage2_result ghostty failed "${GHOSTTY_INSTALL_MESSAGE}; failed to deploy the managed Ghostty config."
        fi
        return 0
      fi
      record_stage2_result ghostty failed "Failed to install Ghostty from the Fedora COPR path documented by Ghostty."
      return 0
      ;;
    zypper)
      skip_with_official_guidance \
        ghostty \
        "Ghostty" \
        "on openSUSE, Ghostty docs recommend building from source or using a third-party community repository."
      return 0
      ;;
  esac

  if ! apt_deb_workflow_supported; then
    skip_with_official_guidance \
      ghostty \
      "Ghostty" \
      "the official docs only document distro packages for Arch/Fedora/Ubuntu, community Debian packaging, and source/community builds elsewhere."
    return 0
  fi

  if ! IFS=$'\t' read -r selector_kind selector_value < <(ghostty_release_selector); then
    record_stage2_result ghostty skipped_unsupported "Ghostty package-managed install supports Debian/Ubuntu only, and this host could not be mapped to a supported release target."
    return 0
  fi

  case "$selector_kind" in
    debian)
      debian_regex="ghostty_.*\\+${selector_value}_${ARCH}\\.deb$"
      if install_ghostty_from_release \
        "dariogriffo/ghostty-debian" \
        "$debian_regex" \
        "dariogriffo/ghostty-debian (${selector_value})"; then
        if deploy_managed_ghostty_config; then
          record_stage2_result ghostty "$GHOSTTY_INSTALL_STATUS" "${GHOSTTY_INSTALL_MESSAGE}; deployed the managed Ghostty config."
        else
          record_stage2_result ghostty failed "${GHOSTTY_INSTALL_MESSAGE}; failed to deploy the managed Ghostty config."
        fi
        return 0
      fi
      record_stage2_result ghostty failed "Failed to install Ghostty from the Debian release feed (dariogriffo/ghostty-debian) for ${selector_value}."
      ;;
    ubuntu)
      ubuntu_regex="ghostty_.*_${ARCH}_${selector_value}\\.deb$"
      if install_ghostty_from_release \
        "mkasberg/ghostty-ubuntu" \
        "$ubuntu_regex" \
        "mkasberg/ghostty-ubuntu (${selector_value//\\/})"; then
        if deploy_managed_ghostty_config; then
          record_stage2_result ghostty "$GHOSTTY_INSTALL_STATUS" "${GHOSTTY_INSTALL_MESSAGE}; deployed the managed Ghostty config."
        else
          record_stage2_result ghostty failed "${GHOSTTY_INSTALL_MESSAGE}; failed to deploy the managed Ghostty config."
        fi
        return 0
      fi
      record_stage2_result ghostty failed "Failed to install Ghostty from mkasberg/ghostty-ubuntu for Ubuntu ${selector_value//\\/}."
      ;;
    *)
      record_stage2_result ghostty skipped_unsupported "Ghostty package-managed install supports Debian/Ubuntu only."
      ;;
  esac
}

install_maple_font() {
  local target_path existing_release_tag status
  local work_dir extract_dir stage_dir staged_font_dir backup_dir font_count

  if [[ "$INSTALL_MAPLE_FONT" -eq 0 ]]; then
    return 0
  fi

  if ! github_release_parse_latest \
    subframe7536/maple-font \
    'MapleMono-NF-CN-unhinted\.zip$' \
    "v"; then
    record_stage2_result maple_font failed "Failed to detect the latest Maple Font release."
    return 0
  fi

  existing_release_tag=""
  if [[ -f "$FONT_DEST_DIR/.release-tag" ]]; then
    existing_release_tag="$(<"$FONT_DEST_DIR/.release-tag")"
  fi

  if [[ -n "$existing_release_tag" && "$existing_release_tag" == "$GITHUB_RELEASE_TAG" ]]; then
    record_stage2_result maple_font already_present "Maple Mono NF CN unhinted ${GITHUB_RELEASE_TAG} is already installed."
    return 0
  fi

  target_path="$ASSET_CACHE_DIR/$GITHUB_ASSET_NAME"
  if ! github_release_download_asset "$GITHUB_ASSET_URL" "$GITHUB_ASSET_DIGEST" "$target_path"; then
    record_stage2_result maple_font failed "Failed to download Maple Mono NF CN unhinted ${GITHUB_RELEASE_TAG}."
    return 0
  fi

  work_dir="$(mktemp -d)"
  extract_dir="$work_dir/extract"
  stage_dir="$work_dir/stage"
  staged_font_dir="$stage_dir/MapleMono-NF-CN-unhinted"
  backup_dir="$work_dir/backup"
  mkdir -p "$extract_dir" "$stage_dir" "$backup_dir"

  ensure_command unzip
  if ! unzip -oq "$target_path" -d "$extract_dir"; then
    rm -rf "$work_dir"
    record_stage2_result maple_font failed "Failed to unpack ${GITHUB_ASSET_NAME}."
    return 0
  fi

  font_count="$(find "$extract_dir" -type f \( -iname '*.ttf' -o -iname '*.otf' \) | wc -l | tr -d '[:space:]')"
  if [[ -z "$font_count" || "$font_count" -eq 0 ]]; then
    rm -rf "$work_dir"
    record_stage2_result maple_font failed "The Maple Font archive was unpacked but no .ttf or .otf files were found."
    return 0
  fi

  ensure_command rsync
  mkdir -p "$staged_font_dir"
  if ! rsync -a "$extract_dir"/ "$staged_font_dir"/; then
    rm -rf "$work_dir"
    record_stage2_result maple_font failed "Failed to stage Maple Font files into the temporary install directory."
    return 0
  fi
  printf '%s\n' "$GITHUB_RELEASE_TAG" > "$staged_font_dir/.release-tag"
  printf '%s\n' "$GITHUB_ASSET_NAME" > "$staged_font_dir/.asset-name"
  printf '%s\n' "$GITHUB_ASSET_URL" > "$staged_font_dir/.source-url"

  mkdir -p "$(dirname "$FONT_DEST_DIR")"
  if [[ -d "$FONT_DEST_DIR" ]]; then
    if ! mv "$FONT_DEST_DIR" "$backup_dir/current"; then
      rm -rf "$work_dir"
      record_stage2_result maple_font failed "Failed to move the existing Maple Font directory out of the way."
      return 0
    fi
  fi

  if ! mv "$staged_font_dir" "$FONT_DEST_DIR"; then
    if [[ -d "$backup_dir/current" ]]; then
      mv "$backup_dir/current" "$FONT_DEST_DIR" || true
    fi
    rm -rf "$work_dir"
    record_stage2_result maple_font failed "Failed to replace the existing Maple Font directory."
    return 0
  fi

  ensure_command fc-cache
  if fc-cache -f "$TARGET_HOME/.local/share/fonts"; then
    ensure_target_path_owned "$FONT_DEST_DIR"
    rm -rf "$work_dir"
    if [[ -n "$existing_release_tag" ]]; then
      status="updated"
    else
      status="installed"
    fi
    record_stage2_result maple_font "$status" "Installed Maple Mono NF CN unhinted ${GITHUB_RELEASE_TAG} and refreshed the font cache."
  else
    rm -rf "$work_dir"
    record_stage2_result maple_font failed "Installed Maple Mono NF CN unhinted ${GITHUB_RELEASE_TAG}, but fc-cache failed."
  fi
}

miniforge_installer_arch() {
  case "$ARCH" in
    amd64)
      printf 'x86_64\n'
      ;;
    arm64)
      printf 'aarch64\n'
      ;;
    ppc64el)
      printf 'ppc64le\n'
      ;;
    *)
      return 1
      ;;
  esac
}

installed_miniforge_version_or_empty() {
  local prefix
  prefix="$1"

  if [[ ! -x "$prefix/bin/conda" ]]; then
    return 0
  fi

  "$prefix/bin/conda" --version 2>/dev/null | awk 'NR==1 {print $2}'
}

install_miniforge() {
  local installer_arch asset_regex target_path status existing_release_tag target_prefix existing_prefix
  local installed_version installed_before=0

  # Miniforge is intentionally installed into a user prefix to avoid system-level ownership and updates.
  if [[ "$INSTALL_MINIFORGE" -eq 0 ]]; then
    return 0
  fi

  if ! installer_arch="$(miniforge_installer_arch)"; then
    record_stage2_result miniforge skipped_unsupported "Miniforge installer mapping is not defined for architecture ${ARCH}."
    return 0
  fi

  asset_regex="Miniforge[^/]*-Linux-${installer_arch}\\.sh$"
  if ! github_release_parse_latest \
    conda-forge/miniforge \
    "$asset_regex" \
    ""; then
    record_stage2_result miniforge failed "Failed to detect the latest Miniforge release."
    return 0
  fi

  existing_prefix="$(HOME="$TARGET_HOME" detect_installed_miniforge_prefix "$MINIFORGE_PREFIX_OVERRIDE" || true)"
  if [[ -n "$existing_prefix" ]]; then
    target_prefix="$existing_prefix"
  else
    target_prefix="$(HOME="$TARGET_HOME" resolve_miniforge_home_prefix "" "$GITHUB_ASSET_NAME" "$MINIFORGE_PREFIX_OVERRIDE" || true)"
  fi

  if [[ -z "$target_prefix" ]]; then
    record_stage2_result miniforge failed "Could not determine the Miniforge install prefix from the latest release metadata."
    return 0
  fi

  existing_release_tag=""
  if [[ -f "$target_prefix/.release-tag" ]]; then
    existing_release_tag="$(<"$target_prefix/.release-tag")"
  fi
  installed_version="$(installed_miniforge_version_or_empty "$target_prefix")"

  if [[ -n "$existing_release_tag" && "$existing_release_tag" == "$GITHUB_RELEASE_TAG" ]]; then
    record_stage2_result miniforge already_present "Miniforge ${GITHUB_RELEASE_TAG} is already installed at ${target_prefix}."
    return 0
  fi

  if [[ -x "$target_prefix/bin/conda" ]]; then
    installed_before=1
  fi

  target_path="$ASSET_CACHE_DIR/$GITHUB_ASSET_NAME"
  if ! github_release_download_asset "$GITHUB_ASSET_URL" "$GITHUB_ASSET_DIGEST" "$target_path"; then
    record_stage2_result miniforge failed "Failed to download Miniforge ${GITHUB_RELEASE_TAG}."
    return 0
  fi

  if [[ -z "$existing_prefix" ]]; then
    target_prefix="$(HOME="$TARGET_HOME" resolve_miniforge_home_prefix "$target_path" "$GITHUB_ASSET_NAME" "$MINIFORGE_PREFIX_OVERRIDE" || true)"
    if [[ -z "$target_prefix" ]]; then
      record_stage2_result miniforge failed "Could not determine the Miniforge install prefix from the downloaded installer."
      return 0
    fi
  fi

  ensure_command bash
  if [[ "$installed_before" -eq 1 ]]; then
    prepare_miniforge_update_prefix "$target_prefix"
  fi
  if ! run_as_target_user "$TARGET_USER" "$TARGET_HOME" bash "$target_path" -b -u -p "$target_prefix"; then
    record_stage2_result miniforge failed "Failed to install Miniforge ${GITHUB_RELEASE_TAG}."
    return 0
  fi

  write_text_file_as_target_user "$target_prefix/.release-tag" "$GITHUB_RELEASE_TAG"
  write_text_file_as_target_user "$target_prefix/.asset-name" "$GITHUB_ASSET_NAME"
  write_text_file_as_target_user "$target_prefix/.source-url" "$GITHUB_ASSET_URL"
  ensure_target_path_owned "$target_prefix"

  installed_version="$(installed_miniforge_version_or_empty "$target_prefix")"
  if [[ "$installed_before" -eq 1 ]]; then
    status="updated"
  else
    status="installed"
  fi
  record_stage2_result miniforge "$status" "Installed Miniforge ${GITHUB_RELEASE_TAG} (conda ${installed_version:-unknown}) at ${target_prefix}."
}

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
