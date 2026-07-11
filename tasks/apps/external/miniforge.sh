#!/usr/bin/env bash

# Miniforge user-prefix adapter.

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
    record_result miniforge skipped_unsupported "Miniforge installer mapping is not defined for architecture ${ARCH}."
    return 0
  fi

  asset_regex="Miniforge[^/]*-Linux-${installer_arch}\\.sh$"
  if ! github_release_parse_latest \
    conda-forge/miniforge \
    "$asset_regex" \
    ""; then
    record_result miniforge failed "Failed to detect the latest Miniforge release."
    return 0
  fi

  existing_prefix="$(HOME="$TARGET_HOME" detect_installed_miniforge_prefix "$MINIFORGE_PREFIX_OVERRIDE" || true)"
  if [[ -n "$existing_prefix" ]]; then
    target_prefix="$existing_prefix"
  else
    target_prefix="$(HOME="$TARGET_HOME" resolve_miniforge_home_prefix "" "$GITHUB_ASSET_NAME" "$MINIFORGE_PREFIX_OVERRIDE" || true)"
  fi

  if [[ -z "$target_prefix" ]]; then
    record_result miniforge failed "Could not determine the Miniforge install prefix from the latest release metadata."
    return 0
  fi

  existing_release_tag=""
  if [[ -f "$target_prefix/.release-tag" ]]; then
    existing_release_tag="$(<"$target_prefix/.release-tag")"
  fi
  installed_version="$(installed_miniforge_version_or_empty "$target_prefix")"

  if [[ -n "$existing_release_tag" && "$existing_release_tag" == "$GITHUB_RELEASE_TAG" ]]; then
    record_result miniforge already_present "Miniforge ${GITHUB_RELEASE_TAG} is already installed at ${target_prefix}."
    return 0
  fi

  if [[ -x "$target_prefix/bin/conda" ]]; then
    installed_before=1
  fi

  target_path="$ASSET_CACHE_DIR/$GITHUB_ASSET_NAME"
  if ! github_release_download_asset "$GITHUB_ASSET_URL" "$GITHUB_ASSET_DIGEST" "$target_path"; then
    record_result miniforge failed "Failed to download Miniforge ${GITHUB_RELEASE_TAG}."
    return 0
  fi

  if [[ -z "$existing_prefix" ]]; then
    target_prefix="$(HOME="$TARGET_HOME" resolve_miniforge_home_prefix "$target_path" "$GITHUB_ASSET_NAME" "$MINIFORGE_PREFIX_OVERRIDE" || true)"
    if [[ -z "$target_prefix" ]]; then
      record_result miniforge failed "Could not determine the Miniforge install prefix from the downloaded installer."
      return 0
    fi
  fi

  ensure_command bash
  if [[ "$installed_before" -eq 1 ]]; then
    prepare_miniforge_update_prefix "$target_prefix"
  fi
  if ! run_as_target_user "$TARGET_USER" "$TARGET_HOME" bash "$target_path" -b -u -p "$target_prefix"; then
    record_result miniforge failed "Failed to install Miniforge ${GITHUB_RELEASE_TAG}."
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
  record_result miniforge "$status" "Installed Miniforge ${GITHUB_RELEASE_TAG} (conda ${installed_version:-unknown}) at ${target_prefix}."
}
