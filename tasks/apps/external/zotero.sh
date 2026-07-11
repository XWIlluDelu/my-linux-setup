#!/usr/bin/env bash

# Zotero repository and official-tarball adapters.

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
    record_result zotero skipped_unsupported "Official Zotero tarballs are not published for architecture ${ARCH}."
    return 0
  fi

  final_url="$(resolve_effective_url_or_empty "$download_url")"
  if [[ -z "$final_url" ]]; then
    record_result zotero failed "Failed to resolve the official Zotero download URL."
    return 0
  fi

  release_version="$(sed -n 's#.*/release/\([^/]*\)/.*#\1#p' <<<"$final_url" | head -n 1)"
  if [[ -z "$release_version" ]]; then
    record_result zotero failed "Failed to determine the Zotero release version from the official download URL."
    return 0
  fi

  installed_version="$(zotero_installed_version_or_empty)"
  if [[ -n "$installed_version" && "$installed_version" == "$release_version" ]]; then
    record_result zotero already_present "Official Zotero tarball ${release_version} is already installed."
    return 0
  fi

  asset_name="$(basename_from_url "$final_url")"
  target_path="$ASSET_CACHE_DIR/$asset_name"
  if ! download_url_with_speed_guard "$download_url" "$target_path"; then
    record_result zotero failed "Failed to download the official Zotero tarball."
    return 0
  fi

  work_dir="$(mktemp -d)"
  extract_dir="$work_dir/extract"
  mkdir -p "$extract_dir"

  if ! tar -xf "$target_path" -C "$extract_dir"; then
    rm -rf "$work_dir"
    record_result zotero failed "Failed to unpack the official Zotero tarball."
    return 0
  fi

  extracted_root="$(find "$extract_dir" -mindepth 1 -maxdepth 1 -type d | head -n 1 || true)"
  if [[ -z "$extracted_root" || ! -x "$extracted_root/zotero" ]]; then
    rm -rf "$work_dir"
    record_result zotero failed "The official Zotero tarball was unpacked, but the Zotero launcher was not found."
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
  record_result zotero "$status" "Installed Zotero ${release_version} from the official tarball and linked it into the user desktop/app path."
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
    record_result zotero failed "Failed to download the third-party Zotero installer script."
    return 0
  fi

  if ! as_root bash "$installer_path"; then
    record_result zotero failed "Failed to run the third-party Zotero installer script."
    return 0
  fi

  if ! apt_noninteractive update; then
    record_result zotero failed "Failed to refresh package metadata after the Zotero third-party repo install."
    return 0
  fi

  if apt_noninteractive install -y zotero; then
    if [[ "$installed_before" -eq 1 ]]; then
      status="updated"
    else
      status="installed"
    fi
    record_result zotero "$status" "Installed Zotero via the retorquere third-party repo path."
  else
    record_result zotero failed "Failed to install Zotero from the retorquere third-party repo."
  fi
}
