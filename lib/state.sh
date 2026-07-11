#!/usr/bin/env bash

# Miniforge discovery and linux-setup managed-state paths.

miniforge_hidden_home_prefix_from_basename() {
  local base_name hidden_name
  base_name="$1"
  [[ -n "$base_name" ]] || return 1

  if [[ "$base_name" == .* ]]; then
    hidden_name="$base_name"
  else
    hidden_name=".$base_name"
  fi

  printf '%s/%s\n' "$HOME" "$hidden_name"
}
miniforge_default_basename_from_asset_name() {
  local asset_name base_name
  asset_name="$1"

  case "$asset_name" in
    Miniforge*-Linux-*.sh)
      base_name="${asset_name%%-Linux-*}"
      printf '%s\n' "${base_name,,}"
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}
miniforge_default_basename_from_installer() {
  local installer_path base_name
  installer_path="$1"
  [[ -r "$installer_path" ]] || return 1

  base_name="$(
    awk -F/ '
      /^PREFIX=/ {
        field = $NF
        sub(/".*$/, "", field)
        if (length(field) > 0) {
          print field
          exit
        }
      }
    ' "$installer_path"
  )"

  [[ -n "$base_name" ]] || return 1
  printf '%s\n' "$base_name"
}
detect_installed_miniforge_prefix() {
  local override_prefix path had_nullglob=0
  override_prefix="${1:-}"

  if [[ -n "$override_prefix" && -x "$override_prefix/bin/conda" ]]; then
    printf '%s\n' "$override_prefix"
    return 0
  fi

  shopt -q nullglob && had_nullglob=1
  shopt -s nullglob

  for path in "$HOME"/.miniforge*; do
    if [[ -x "$path/bin/conda" ]]; then
      (( had_nullglob == 1 )) || shopt -u nullglob
      printf '%s\n' "$path"
      return 0
    fi
  done

  for path in "$HOME"/miniforge*; do
    if [[ -x "$path/bin/conda" ]]; then
      (( had_nullglob == 1 )) || shopt -u nullglob
      printf '%s\n' "$path"
      return 0
    fi
  done

  (( had_nullglob == 1 )) || shopt -u nullglob
  return 1
}
resolve_miniforge_home_prefix() {
  local installer_path asset_name override_prefix base_name
  installer_path="${1:-}"
  asset_name="${2:-}"
  override_prefix="${3:-}"

  if [[ -n "$override_prefix" ]]; then
    printf '%s\n' "$override_prefix"
    return 0
  fi

  base_name=""
  if [[ -n "$installer_path" ]]; then
    base_name="$(miniforge_default_basename_from_installer "$installer_path" || true)"
  fi

  if [[ -z "$base_name" && -n "$asset_name" ]]; then
    base_name="$(miniforge_default_basename_from_asset_name "$asset_name" || true)"
  fi

  [[ -n "$base_name" ]] || return 1
  miniforge_hidden_home_prefix_from_basename "$base_name"
}
linux_setup_state_dir() {
  printf '%s\n' "$HOME/.local/state/linux-setup"
}
linux_setup_state_dir_for_home() {
  local target_home
  target_home="$1"
  printf '%s/.local/state/linux-setup\n' "$target_home"
}
shell_env_state_file() {
  printf '%s/shell-env.env\n' "$(linux_setup_state_dir)"
}
shell_env_state_file_for_home() {
  local target_home
  target_home="$1"
  printf '%s/shell-env.env\n' "$(linux_setup_state_dir_for_home "$target_home")"
}
shell_env_profile_marker() {
  printf '%s/shell-env-profile\n' "$(linux_setup_state_dir)"
}
shell_env_profile_marker_for_home() {
  local target_home
  target_home="$1"
  printf '%s/shell-env-profile\n' "$(linux_setup_state_dir_for_home "$target_home")"
}
read_env_file_value() {
  local state_file key
  state_file="$1"
  key="$2"
  [[ -r "$state_file" ]] || return 1

  awk -F= -v key="$key" '
    $1 == key {
      value = substr($0, index($0, "=") + 1)
      gsub(/^"/, "", value)
      gsub(/"$/, "", value)
      print value
      exit
    }
  ' "$state_file"
}
read_shell_env_state_value() {
  local state_file key
  state_file="${1:-$(shell_env_state_file)}"
  key="$2"
  read_env_file_value "$state_file" "$key"
}
read_shell_env_profile_marker_value() {
  local marker_path recorded
  marker_path="$1"

  [[ -r "$marker_path" ]] || return 1
  recorded="$(head -n 1 "$marker_path" 2>/dev/null | tr -d '[:space:]' || true)"
  case "$recorded" in
    desktop|server)
      printf '%s\n' "$recorded"
      ;;
    *)
      return 1
      ;;
  esac
}
shell_env_profile_from_state_or_marker() {
  local target_home state_file marker_file profile
  target_home="${1:-$HOME}"
  state_file="$(shell_env_state_file_for_home "$target_home")"
  marker_file="$(shell_env_profile_marker_for_home "$target_home")"

  profile="$(read_shell_env_state_value "$state_file" SHELL_ENV_PROFILE 2>/dev/null || true)"
  case "$profile" in
    desktop|server)
      printf '%s\n' "$profile"
      return 0
      ;;
  esac

  read_shell_env_profile_marker_value "$marker_file"
}
detect_managed_shell_env() {
  local target_home state_file marker_file managed profile
  target_home="${1:-$HOME}"
  state_file="$(shell_env_state_file_for_home "$target_home")"
  marker_file="$(shell_env_profile_marker_for_home "$target_home")"

  managed="$(read_shell_env_state_value "$state_file" SHELL_ENV_MANAGED 2>/dev/null || true)"
  profile="$(read_shell_env_state_value "$state_file" SHELL_ENV_PROFILE 2>/dev/null || true)"
  if [[ "$managed" == "1" ]]; then
    case "$profile" in
      desktop|server)
        return 0
        ;;
    esac
  fi

  profile="$(read_shell_env_profile_marker_value "$marker_file" 2>/dev/null || true)"
  case "$profile" in
    desktop|server)
      return 0
      ;;
  esac

  return 1
}
