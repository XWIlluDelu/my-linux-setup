#!/usr/bin/env bash

# Clash Verge Rev distro package adapters.

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
    record_result "$result_id" failed "Failed to detect the latest ${human_name} release."
    return 0
  fi

  installed_version="$(installed_version_or_empty "$package_name")"
  if [[ -n "$installed_version" && "$installed_version" == "$GITHUB_RELEASE_VERSION" ]]; then
    record_result "$result_id" already_present "${human_name} ${installed_version} already matches the latest release ${GITHUB_RELEASE_TAG}."
    return 0
  fi

  if [[ -n "$installed_version" ]]; then
    installed_before=1
  fi

  target_path="$DEB_CACHE_DIR/$GITHUB_ASSET_NAME"
  if ! github_release_download_asset "$GITHUB_ASSET_URL" "$GITHUB_ASSET_DIGEST" "$target_path"; then
    record_result "$result_id" failed "Failed to download ${human_name} ${GITHUB_RELEASE_TAG}."
    return 0
  fi

  ensure_command dpkg-deb
  deb_package="$(read_deb_field_or_empty "$target_path" Package)"
  deb_version="$(read_deb_field_or_empty "$target_path" Version)"
  if [[ -z "$deb_package" || -z "$deb_version" ]]; then
    record_result "$result_id" failed "${human_name} download is not a valid .deb or is missing Package/Version metadata."
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
    record_result "$result_id" "$status" "Installed ${human_name} ${deb_version} from ${GITHUB_RELEASE_TAG}."
  else
    record_result "$result_id" failed "Failed to install ${human_name} from ${GITHUB_ASSET_NAME}."
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
    record_result clash_verge_rev skipped_unsupported "Official Clash Verge Rev rpm assets are not published for architecture ${ARCH}."
    record_result clash_verge_rev_service skipped_unsupported "Clash Verge Rev service mode is unavailable because no supported rpm asset exists for ${ARCH}."
    return 0
  fi

  asset_regex="Clash\\.Verge-.*-1\\.${rpm_arch}\\.rpm$"
  if ! github_release_parse_latest \
    clash-verge-rev/clash-verge-rev \
    "$asset_regex" \
    "v"; then
    record_result clash_verge_rev failed "Failed to detect the latest Clash Verge Rev rpm release."
    record_result clash_verge_rev_service skipped_unavailable "Clash Verge Rev service mode was not attempted because the rpm release metadata could not be resolved."
    return 0
  fi

  target_path="$ASSET_CACHE_DIR/$GITHUB_ASSET_NAME"
  if ! github_release_download_asset "$GITHUB_ASSET_URL" "$GITHUB_ASSET_DIGEST" "$target_path"; then
    record_result clash_verge_rev failed "Failed to download Clash Verge Rev ${GITHUB_RELEASE_TAG}."
    record_result clash_verge_rev_service skipped_unavailable "Clash Verge Rev service mode was not attempted because the rpm asset failed to download."
    return 0
  fi

  ensure_command rpm
  rpm_package="$(read_rpm_field_or_empty "$target_path" Name)"
  rpm_version="$(read_rpm_field_or_empty "$target_path" VersionRelease)"
  if [[ -z "$rpm_package" || -z "$rpm_version" ]]; then
    record_result clash_verge_rev failed "Downloaded Clash Verge Rev rpm is invalid or missing Name/Version metadata."
    record_result clash_verge_rev_service skipped_unavailable "Clash Verge Rev service mode was not attempted because the rpm metadata could not be read."
    return 0
  fi

  installed_version="$(installed_package_version_for_current_manager "$rpm_package")"
  if [[ -n "$installed_version" && "$installed_version" == "$rpm_version" ]]; then
    record_result clash_verge_rev already_present "Clash Verge Rev ${rpm_version} already matches the latest rpm release ${GITHUB_RELEASE_TAG}."
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
      record_result clash_verge_rev "$status" "Installed Clash Verge Rev ${rpm_version} from ${GITHUB_RELEASE_TAG}."
    else
      record_result clash_verge_rev failed "Failed to install Clash Verge Rev from ${GITHUB_ASSET_NAME}."
    fi
  fi

  if command_exists clash-verge-service-install; then
    info "Installing Clash Verge Rev service mode (required for TUN)..."
    if as_root clash-verge-service-install; then
      info "Clash Verge Rev service mode installed successfully."
      record_result clash_verge_rev_service configured "Installed Clash Verge Rev service mode for TUN."
    else
      warn "Failed to install Clash Verge Rev service mode. TUN will not work until service mode is installed manually."
      record_result clash_verge_rev_service failed "Failed to install Clash Verge Rev service mode for TUN."
    fi
  else
    record_result clash_verge_rev_service skipped_unavailable "Clash Verge Rev service installer was not available after rpm installation."
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
    record_result clash_verge_rev failed "Failed to bootstrap yay for the official Arch Linux installation path."
    record_result clash_verge_rev_service skipped_unavailable "Clash Verge Rev service mode was not attempted because yay setup failed."
    return 0
  fi

  installed_version="$(installed_package_version_for_current_manager "$package_name")"
  if [[ -n "$installed_version" ]]; then
    installed_before=1
  fi

  if ! run_as_target_user "$TARGET_USER" "$TARGET_HOME" yay -S --noconfirm --needed "$package_name"; then
    record_result clash_verge_rev failed "Failed to install Clash Verge Rev via the official Arch Linux yay workflow."
    record_result clash_verge_rev_service skipped_unavailable "Clash Verge Rev service mode was not attempted because the Arch package install failed."
    return 0
  fi

  final_version="$(installed_package_version_for_current_manager "$package_name")"
  if [[ -z "$final_version" ]]; then
    record_result clash_verge_rev failed "Clash Verge Rev Arch package install completed, but the package is not queryable afterward."
  elif [[ "$installed_before" -eq 1 && "$installed_version" == "$final_version" ]]; then
    record_result clash_verge_rev already_present "Clash Verge Rev ${final_version} is already installed from the official Arch Linux package path."
  elif [[ "$installed_before" -eq 1 ]]; then
    record_result clash_verge_rev updated "Updated Clash Verge Rev to ${final_version} via the official Arch Linux package path."
  else
    status="installed"
    record_result clash_verge_rev "$status" "Installed Clash Verge Rev ${final_version} via the official Arch Linux package path."
  fi

  if command_exists clash-verge-service-install; then
    info "Installing Clash Verge Rev service mode (required for TUN)..."
    if as_root clash-verge-service-install; then
      info "Clash Verge Rev service mode installed successfully."
      record_result clash_verge_rev_service configured "Installed Clash Verge Rev service mode for TUN."
    else
      warn "Failed to install Clash Verge Rev service mode. TUN will not work until service mode is installed manually."
      record_result clash_verge_rev_service failed "Failed to install Clash Verge Rev service mode for TUN."
    fi
  else
    record_result clash_verge_rev_service skipped_unavailable "Clash Verge Rev service installer was not available after Arch package installation."
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
        record_result clash_verge_rev_service configured "Installed Clash Verge Rev service mode for TUN."
      else
        warn "Failed to install Clash Verge Rev service mode. TUN will not work until service mode is installed manually."
        record_result clash_verge_rev_service failed "Failed to install Clash Verge Rev service mode for TUN."
      fi
    else
      record_result clash_verge_rev_service skipped_unavailable "Clash Verge Rev service installer was not available after package installation."
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
      record_result clash_verge_rev_service skipped_unsupported "Clash Verge Rev service mode is only automated for the official package paths."
      ;;
  esac
}
