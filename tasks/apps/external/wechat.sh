#!/usr/bin/env bash

# WeChat official package adapter.

install_wechat_official_deb() {
  local deb_path package_name package_version installed_before=0 status
  local installed_version

  # Official .deb packages integrate with the system package database, so this stays system-wide.
  if [[ "$ARCH" != "amd64" ]]; then
    record_result wechat skipped_unsupported "Official WeChat .deb is only supported on amd64."
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
    record_result wechat failed "Failed to download the official WeChat .deb."
    return 0
  fi

  ensure_command dpkg-deb
  package_name="$(read_deb_field_or_empty "$deb_path" Package)"
  package_version="$(read_deb_field_or_empty "$deb_path" Version)"
  if [[ -z "$package_name" || -z "$package_version" ]]; then
    record_result wechat failed "Downloaded WeChat package is not a valid .deb or is missing Package/Version metadata."
    return 0
  fi
  installed_version="$(installed_version_or_empty "$package_name")"

  if [[ -n "$installed_version" && "$installed_version" == "$package_version" ]]; then
    record_result wechat already_present "Official WeChat .deb ${package_version} is already installed."
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
    record_result wechat "$status" "Installed official WeChat .deb ${package_version}."
  else
    record_result wechat failed "Failed to install the official WeChat .deb."
  fi
}
install_wechat() {
  if [[ "$INSTALL_WECHAT" -eq 0 ]]; then
    return 0
  fi

  install_wechat_official_deb
}
