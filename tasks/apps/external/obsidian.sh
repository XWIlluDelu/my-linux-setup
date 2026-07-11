#!/usr/bin/env bash

# Obsidian official package and AppImage adapters.

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
    record_result obsidian skipped_unsupported "Official Obsidian AppImages are not published for architecture ${ARCH}, or the official download page could not be parsed."
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
    record_result obsidian already_present "Official Obsidian AppImage ${release_version} is already installed."
    return 0
  fi

  target_path="$ASSET_CACHE_DIR/$asset_name"
  if [[ "$official_url" == https://github.com/* ]]; then
    if ! github_release_download_asset "$official_url" "" "$target_path"; then
      record_result obsidian failed "Failed to download the official Obsidian AppImage ${release_version}."
      return 0
    fi
  elif ! download_url_with_speed_guard "$official_url" "$target_path"; then
    record_result obsidian failed "Failed to download the official Obsidian AppImage ${release_version}."
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
  record_result obsidian "$status" "Installed Obsidian ${release_version} from the official AppImage and integrated it into the user desktop/app path."
}
install_obsidian_official_deb() {
  local official_url target_path installed_before=0 status
  local deb_package deb_version installed_version

  official_url="$(resolve_obsidian_download_from_official_page deb-amd64)"
  if [[ -z "$official_url" ]]; then
    record_result obsidian failed "Failed to resolve the official Obsidian .deb download URL from the download page."
    return 0
  fi

  target_path="$DEB_CACHE_DIR/$(basename_from_url "$official_url")"
  if [[ "$official_url" == https://github.com/* ]]; then
    if ! github_release_download_asset "$official_url" "" "$target_path"; then
      record_result obsidian failed "Failed to download the official Obsidian .deb."
      return 0
    fi
  elif ! download_url_with_speed_guard "$official_url" "$target_path"; then
    record_result obsidian failed "Failed to download the official Obsidian .deb."
    return 0
  fi

  ensure_command dpkg-deb
  deb_package="$(read_deb_field_or_empty "$target_path" Package)"
  deb_version="$(read_deb_field_or_empty "$target_path" Version)"
  if [[ -z "$deb_package" || -z "$deb_version" ]]; then
    record_result obsidian failed "Downloaded Obsidian package is not a valid .deb or is missing Package/Version metadata."
    return 0
  fi

  installed_version="$(installed_version_or_empty "$deb_package")"
  if [[ -n "$installed_version" && "$installed_version" == "$deb_version" ]]; then
    record_result obsidian already_present "Official Obsidian .deb ${deb_version} is already installed."
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
    record_result obsidian "$status" "Installed Obsidian ${deb_version} from the official download page."
  else
    record_result obsidian failed "Failed to install Obsidian from the official .deb package."
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
    record_result obsidian skipped_unsupported "The official Obsidian .deb workflow is only implemented for amd64; use the AppImage path on other architectures."
    return 0
  fi

  install_obsidian_official_deb
}
