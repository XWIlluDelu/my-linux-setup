#!/usr/bin/env bash

# Maple Mono NF CN user-font adapter.

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
    record_result maple_font failed "Failed to detect the latest Maple Font release."
    return 0
  fi

  existing_release_tag=""
  if [[ -f "$FONT_DEST_DIR/.release-tag" ]]; then
    existing_release_tag="$(<"$FONT_DEST_DIR/.release-tag")"
  fi

  if [[ -n "$existing_release_tag" && "$existing_release_tag" == "$GITHUB_RELEASE_TAG" ]]; then
    record_result maple_font already_present "Maple Mono NF CN unhinted ${GITHUB_RELEASE_TAG} is already installed."
    return 0
  fi

  target_path="$ASSET_CACHE_DIR/$GITHUB_ASSET_NAME"
  if ! github_release_download_asset "$GITHUB_ASSET_URL" "$GITHUB_ASSET_DIGEST" "$target_path"; then
    record_result maple_font failed "Failed to download Maple Mono NF CN unhinted ${GITHUB_RELEASE_TAG}."
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
    record_result maple_font failed "Failed to unpack ${GITHUB_ASSET_NAME}."
    return 0
  fi

  font_count="$(find "$extract_dir" -type f \( -iname '*.ttf' -o -iname '*.otf' \) | wc -l | tr -d '[:space:]')"
  if [[ -z "$font_count" || "$font_count" -eq 0 ]]; then
    rm -rf "$work_dir"
    record_result maple_font failed "The Maple Font archive was unpacked but no .ttf or .otf files were found."
    return 0
  fi

  ensure_command rsync
  mkdir -p "$staged_font_dir"
  if ! rsync -a "$extract_dir"/ "$staged_font_dir"/; then
    rm -rf "$work_dir"
    record_result maple_font failed "Failed to stage Maple Font files into the temporary install directory."
    return 0
  fi
  printf '%s\n' "$GITHUB_RELEASE_TAG" > "$staged_font_dir/.release-tag"
  printf '%s\n' "$GITHUB_ASSET_NAME" > "$staged_font_dir/.asset-name"
  printf '%s\n' "$GITHUB_ASSET_URL" > "$staged_font_dir/.source-url"

  mkdir -p "$(dirname "$FONT_DEST_DIR")"
  if [[ -d "$FONT_DEST_DIR" ]]; then
    if ! mv "$FONT_DEST_DIR" "$backup_dir/current"; then
      rm -rf "$work_dir"
      record_result maple_font failed "Failed to move the existing Maple Font directory out of the way."
      return 0
    fi
  fi

  if ! mv "$staged_font_dir" "$FONT_DEST_DIR"; then
    if [[ -d "$backup_dir/current" ]]; then
      mv "$backup_dir/current" "$FONT_DEST_DIR" || true
    fi
    rm -rf "$work_dir"
    record_result maple_font failed "Failed to replace the existing Maple Font directory."
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
    record_result maple_font "$status" "Installed Maple Mono NF CN unhinted ${GITHUB_RELEASE_TAG} and refreshed the font cache."
  else
    rm -rf "$work_dir"
    record_result maple_font failed "Installed Maple Mono NF CN unhinted ${GITHUB_RELEASE_TAG}, but fc-cache failed."
  fi
}
