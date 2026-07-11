#!/usr/bin/env bash

# Ghostty distro adapters and managed configuration.

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
          record_result ghostty "$GHOSTTY_INSTALL_STATUS" "${GHOSTTY_INSTALL_MESSAGE}; deployed the managed Ghostty config."
        else
          record_result ghostty failed "${GHOSTTY_INSTALL_MESSAGE}; failed to deploy the managed Ghostty config."
        fi
        return 0
      fi
      record_result ghostty failed "Failed to install Ghostty from the official Arch Linux package repository."
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
        record_result ghostty failed "Failed to enable the official-doc Fedora COPR for Ghostty."
        return 0
      fi
      if install_ghostty_via_system_package "the Fedora COPR path documented by Ghostty"; then
        if deploy_managed_ghostty_config; then
          record_result ghostty "$GHOSTTY_INSTALL_STATUS" "${GHOSTTY_INSTALL_MESSAGE}; deployed the managed Ghostty config."
        else
          record_result ghostty failed "${GHOSTTY_INSTALL_MESSAGE}; failed to deploy the managed Ghostty config."
        fi
        return 0
      fi
      record_result ghostty failed "Failed to install Ghostty from the Fedora COPR path documented by Ghostty."
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
    record_result ghostty skipped_unsupported "Ghostty package-managed install supports Debian/Ubuntu only, and this host could not be mapped to a supported release target."
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
          record_result ghostty "$GHOSTTY_INSTALL_STATUS" "${GHOSTTY_INSTALL_MESSAGE}; deployed the managed Ghostty config."
        else
          record_result ghostty failed "${GHOSTTY_INSTALL_MESSAGE}; failed to deploy the managed Ghostty config."
        fi
        return 0
      fi
      record_result ghostty failed "Failed to install Ghostty from the Debian release feed (dariogriffo/ghostty-debian) for ${selector_value}."
      ;;
    ubuntu)
      ubuntu_regex="ghostty_.*_${ARCH}_${selector_value}\\.deb$"
      if install_ghostty_from_release \
        "mkasberg/ghostty-ubuntu" \
        "$ubuntu_regex" \
        "mkasberg/ghostty-ubuntu (${selector_value//\\/})"; then
        if deploy_managed_ghostty_config; then
          record_result ghostty "$GHOSTTY_INSTALL_STATUS" "${GHOSTTY_INSTALL_MESSAGE}; deployed the managed Ghostty config."
        else
          record_result ghostty failed "${GHOSTTY_INSTALL_MESSAGE}; failed to deploy the managed Ghostty config."
        fi
        return 0
      fi
      record_result ghostty failed "Failed to install Ghostty from mkasberg/ghostty-ubuntu for Ubuntu ${selector_value//\\/}."
      ;;
    *)
      record_result ghostty skipped_unsupported "Ghostty package-managed install supports Debian/Ubuntu only."
      ;;
  esac
}
