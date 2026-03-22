#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

# Community-standard scope: repository-managed apps are installed system-wide.
KEY_URL="https://packages.microsoft.com/keys/microsoft.asc"
KEYRING_PATH="/usr/share/keyrings/microsoft.gpg"
VSCODE_LIST="/etc/apt/sources.list.d/vscode.list"
VSCODE_DEB822_LIST="/etc/apt/sources.list.d/vscode.sources"
EDGE_LIST="/etc/apt/sources.list.d/microsoft-edge.list"
TMP_KEY=""

DESKTOP_ESSENTIALS=1
INSTALL_VSCODE=1
INSTALL_EDGE=1
MICROSOFT_REPOS_READY=1

cleanup() {
  if [[ -n "${TMP_KEY:-}" && -f "${TMP_KEY:-}" ]]; then
    rm -f "$TMP_KEY"
  fi
}
trap cleanup EXIT

usage() {
  cat <<'EOF'
Install selected packaged desktop apps on Debian/Ubuntu.

Usage:
  install-apt-apps.sh [--check] [--apply]
    [--desktop-essentials 0|1]
    [--vscode 0|1]
    [--edge 0|1]

Notes:
  - Default mode is --check.
EOF
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

record_result_for_disabled_items() {
  if [[ "$DESKTOP_ESSENTIALS" -eq 0 ]]; then
    record_stage2_result desktop_essentials skipped_not_selected "Skipped by stage2 selection."
  fi
  if [[ "$INSTALL_VSCODE" -eq 0 ]]; then
    record_stage2_result vscode skipped_not_selected "Skipped by stage2 selection."
  fi
  if [[ "$INSTALL_EDGE" -eq 0 ]]; then
    record_stage2_result edge skipped_not_selected "Skipped by stage2 selection."
  fi
}

mark_repo_failure() {
  local message
  message="$1"

  MICROSOFT_REPOS_READY=0
  if [[ "$INSTALL_VSCODE" -eq 1 ]]; then
    record_stage2_result vscode failed "$message"
  fi
  if [[ "$INSTALL_EDGE" -eq 1 && "$ARCH" == "amd64" ]]; then
    record_stage2_result edge failed "$message"
  fi
}

prune_conflicting_microsoft_sources() {
  local changed=0

  # Some systems already ship deb822 source files for Microsoft repos with a
  # different Signed-By keyring path. Keep one canonical source definition to
  # avoid apt errors like:
  # "Conflicting values set for option Signed-By ..."
  if [[ -f "$VSCODE_DEB822_LIST" ]]; then
    info "Removing conflicting VS Code source definition: $VSCODE_DEB822_LIST"
    as_root rm -f "$VSCODE_DEB822_LIST"
    changed=1
  fi

  if [[ -f "/etc/apt/sources.list.d/microsoft-edge.sources" ]]; then
    info "Removing conflicting Edge source definition: /etc/apt/sources.list.d/microsoft-edge.sources"
    as_root rm -f "/etc/apt/sources.list.d/microsoft-edge.sources"
    changed=1
  fi

  if [[ "$changed" -eq 1 ]]; then
    info "Removed conflicting Microsoft source definitions before apt refresh."
  fi
}

setup_microsoft_repos() {
  prune_conflicting_microsoft_sources

  info "[1/4] Install Microsoft repository prerequisites"
  apt_noninteractive update
  apt_noninteractive install -y ca-certificates curl gpg

  info "[2/4] Install Microsoft signing key"
  TMP_KEY="$(mktemp)"
  curl -fsSL "$KEY_URL" | gpg --dearmor > "$TMP_KEY"
  as_root install -o root -g root -m 644 "$TMP_KEY" "$KEYRING_PATH"

  info "[3/4] Configure Microsoft APT repositories"
  if [[ "$INSTALL_VSCODE" -eq 1 ]]; then
    printf 'deb [arch=%s signed-by=%s] https://packages.microsoft.com/repos/code stable main\n' \
      "$ARCH" "$KEYRING_PATH" \
      | as_root tee "$VSCODE_LIST" >/dev/null
  fi

  if [[ "$INSTALL_EDGE" -eq 1 ]]; then
    if [[ "$ARCH" == "amd64" ]]; then
      printf 'deb [arch=amd64 signed-by=%s] https://packages.microsoft.com/repos/edge stable main\n' \
        "$KEYRING_PATH" \
        | as_root tee "$EDGE_LIST" >/dev/null
    else
      warn "Edge is only available from the official repo on amd64. Skipping Edge source for $ARCH."
      record_stage2_result edge skipped_unsupported "Microsoft Edge official repo only supports amd64."
    fi
  fi

  info "[4/4] Refresh package metadata after repo changes"
  apt_noninteractive update
}

install_desktop_essentials() {
  local -a packages optional_packages
  local preinstalled_count=0 status

  if [[ "$DESKTOP_ESSENTIALS" -eq 0 ]]; then
    return 0
  fi

  packages=(mpv)
  optional_packages=(gnome-tweaks gnome-shell-extension-manager)

  for pkg in "${optional_packages[@]}"; do
    if package_available "$pkg"; then
      packages+=("$pkg")
    else
      warn "Package not available after apt-get update, skipped: $pkg"
    fi
  done

  for pkg in "${packages[@]}"; do
    if dpkg_package_installed "$pkg"; then
      preinstalled_count=$((preinstalled_count + 1))
    fi
  done

  if apt_noninteractive install -y "${packages[@]}"; then
    if [[ "$preinstalled_count" -eq "${#packages[@]}" ]]; then
      status="updated"
    else
      status="installed"
    fi
    record_stage2_result desktop_essentials "$status" "Installed desktop essentials: ${packages[*]}"
  else
    record_stage2_result desktop_essentials failed "Failed to install desktop essentials."
  fi
}

install_vscode() {
  local installed_before=0 status

  if [[ "$INSTALL_VSCODE" -eq 0 ]]; then
    return 0
  fi

  if [[ "$MICROSOFT_REPOS_READY" -ne 1 ]]; then
    return 0
  fi

  if ! package_available code; then
    record_stage2_result vscode failed "Package 'code' is not available from the Microsoft repo."
    return 0
  fi

  if dpkg_package_installed code; then
    installed_before=1
  fi

  if apt_noninteractive install -y code; then
    if [[ "$installed_before" -eq 1 ]]; then
      status="updated"
    else
      status="installed"
    fi
    record_stage2_result vscode "$status" "Installed Visual Studio Code from the Microsoft repository."
  else
    record_stage2_result vscode failed "Failed to install Visual Studio Code."
  fi
}

install_edge() {
  local installed_before=0 status

  if [[ "$INSTALL_EDGE" -eq 0 ]]; then
    return 0
  fi

  if [[ "$ARCH" != "amd64" ]]; then
    return 0
  fi

  if [[ "$MICROSOFT_REPOS_READY" -ne 1 ]]; then
    return 0
  fi

  if ! package_available microsoft-edge-stable; then
    record_stage2_result edge failed "Package 'microsoft-edge-stable' is not available for this distro/repo combination."
    return 0
  fi

  if dpkg_package_installed microsoft-edge-stable; then
    installed_before=1
  fi

  if apt_noninteractive install -y microsoft-edge-stable; then
    if [[ "$installed_before" -eq 1 ]]; then
      status="updated"
    else
      status="installed"
    fi
    record_stage2_result edge "$status" "Installed Microsoft Edge from the Microsoft repository."
  else
    record_stage2_result edge failed "Failed to install Microsoft Edge."
  fi
}

purge_debian_desktop_defaults() {
  local -a purge_candidates installed_packages protected_metapackages safe_packages skipped_packages
  local status message

  detect_os_release
  if [[ "$DISTRO_ID" != "debian" ]]; then
    return 0
  fi

  purge_candidates=(
    evolution
    firefox-esr
    epiphany-browser
    gnome-calendar
    gnome-contacts
    gnome-clocks
    gnome-maps
    gnome-music
    gnome-snapshot
    gnome-sound-recorder
    gnome-tour
    gnome-weather
    gnome-characters
    loupe
    rhythmbox
    simple-scan
    totem
    yelp
  )
  protected_metapackages=(
    gnome
    gnome-core
    task-gnome-desktop
  )
  installed_packages=()

  for pkg in "${purge_candidates[@]}"; do
    if dpkg_package_installed "$pkg"; then
      installed_packages+=("$pkg")
    fi
  done

  if [[ "${#installed_packages[@]}" -eq 0 ]]; then
    record_stage2_result desktop_cleanup already_present "No Debian desktop defaults matched the cleanup list."
    return 0
  fi

  safe_packages=()
  skipped_packages=()

  while IFS= read -r pkg; do
    if would_remove_protected_metapackages protected_metapackages "${safe_packages[@]}" "$pkg"; then
      skipped_packages+=("$pkg")
    else
      safe_packages+=("$pkg")
    fi
  done < <(printf '%s\n' "${installed_packages[@]}")

  if [[ "${#safe_packages[@]}" -eq 0 ]]; then
    message="Skipped Debian desktop cleanup because every candidate would remove protected desktop metapackages: ${installed_packages[*]}"
    warn "$message"
    record_stage2_result desktop_cleanup already_present "$message"
    return 0
  fi

  info "[debian] Purge unwanted default desktop apps: ${safe_packages[*]}"
  if [[ "${#skipped_packages[@]}" -gt 0 ]]; then
    warn "[debian] Keeping these packages to avoid removing GNOME metapackages: ${skipped_packages[*]}"
  fi

  if apt_noninteractive purge -y "${safe_packages[@]}"; then
    status="updated"
    message="Purged Debian desktop defaults: ${safe_packages[*]}"
    if [[ "${#skipped_packages[@]}" -gt 0 ]]; then
      message="${message}; kept to preserve desktop metapackages: ${skipped_packages[*]}"
    fi
    record_stage2_result desktop_cleanup "$status" "$message"
  else
    message="Failed to purge Debian desktop defaults: ${safe_packages[*]}"
    if [[ "${#skipped_packages[@]}" -gt 0 ]]; then
      message="${message}; skipped to preserve desktop metapackages: ${skipped_packages[*]}"
    fi
    record_stage2_result desktop_cleanup failed "$message"
  fi
}

apt_noninteractive_simulate() {
  ensure_command apt-get

  if [[ "$EUID" -eq 0 ]]; then
    env \
      DEBIAN_FRONTEND=noninteractive \
      UCF_FORCE_CONFOLD=1 \
      apt-get \
      -s \
      -o Dpkg::Options::=--force-confdef \
      -o Dpkg::Options::=--force-confold \
      "$@"
  else
    sudo env \
      DEBIAN_FRONTEND=noninteractive \
      UCF_FORCE_CONFOLD=1 \
      apt-get \
      -s \
      -o Dpkg::Options::=--force-confdef \
      -o Dpkg::Options::=--force-confold \
      "$@"
  fi
}

would_remove_protected_metapackages() {
  local -n protected_ref="$1"
  shift

  local simulation pkg
  simulation="$(apt_noninteractive_simulate purge -y "$@" 2>/dev/null || true)"

  for pkg in "${protected_ref[@]}"; do
    if grep -Eq "^(Remv|Purg) ${pkg}([ :]|$)" <<< "$simulation"; then
      return 0
    fi
  done

  return 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)
      APPLY=0
      ;;
    --apply)
      APPLY=1
      ;;
    --desktop-essentials)
      [[ $# -ge 2 ]] || die "--desktop-essentials requires a value"
      DESKTOP_ESSENTIALS="$(parse_bool "$1" "$2")"
      shift
      ;;
    --vscode)
      [[ $# -ge 2 ]] || die "--vscode requires a value"
      INSTALL_VSCODE="$(parse_bool "$1" "$2")"
      shift
      ;;
    --edge)
      [[ $# -ge 2 ]] || die "--edge requires a value"
      INSTALL_EDGE="$(parse_bool "$1" "$2")"
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

ensure_command sudo
ensure_command apt-get
ensure_command apt-cache
ensure_command dpkg
ensure_command curl
ensure_command gpg
ensure_command install
ARCH="$(dpkg --print-architecture)"

if [[ "$APPLY" -ne 1 ]]; then
  cat <<EOF
This was a check run. The script would:
  1. Configure the Microsoft repositories when VS Code or Edge is selected
  2. Install desktop essentials when selected: mpv, gnome-tweaks, gnome-shell-extension-manager
  3. Install Visual Studio Code when selected
  4. Install Microsoft Edge when selected and supported
  5. On Debian, purge unwanted default desktop apps if present: evolution, firefox-esr, epiphany-browser, gnome-calendar, gnome-contacts, gnome-clocks, gnome-maps, gnome-music, gnome-snapshot, gnome-sound-recorder, gnome-tour, gnome-weather, gnome-characters, loupe, rhythmbox, simple-scan, totem, yelp

Current selection:
  - desktop_essentials=$DESKTOP_ESSENTIALS
  - vscode=$INSTALL_VSCODE
  - edge=$INSTALL_EDGE

Run with --apply to execute.
EOF
  exit 0
fi

record_result_for_disabled_items

if [[ "$DESKTOP_ESSENTIALS" -eq 0 && "$INSTALL_VSCODE" -eq 0 && "$INSTALL_EDGE" -eq 0 ]]; then
  info "No packaged desktop apps were selected."
  exit 0
fi

ensure_sudo_session

if [[ "$INSTALL_VSCODE" -eq 1 || "$INSTALL_EDGE" -eq 1 ]]; then
  if ! setup_microsoft_repos; then
    warn "Microsoft repository setup failed."
    mark_repo_failure "Failed to configure Microsoft repositories."
  fi
fi

install_desktop_essentials
install_vscode
install_edge
purge_debian_desktop_defaults
