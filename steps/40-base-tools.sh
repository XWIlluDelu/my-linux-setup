#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

usage() {
  cat <<'EOF'
Install base command-line tools and build prerequisites.

Usage:
  40-base-tools.sh [--check] [--apply]

Notes:
  - Default mode is --check.
  - Supports apt, dnf, zypper, and pacman.
EOF
}

PKG_MANAGER="$(detect_pkg_manager 2>/dev/null || true)"
[[ -n "$PKG_MANAGER" ]] || die "No supported package manager detected. Supported: apt, dnf, zypper, pacman."

base_tool_packages() {
  case "$PKG_MANAGER" in
    apt-get)
      printf '%s\n' \
        build-essential \
        dkms \
        git \
        wget \
        curl \
        ca-certificates \
        gpg \
        rsync \
        jq \
        ripgrep \
        fd-find \
        tree \
        unzip \
        zip \
        htop \
        vim
      ;;
    dnf)
      printf '%s\n' \
        gcc \
        gcc-c++ \
        make \
        dkms \
        git \
        wget2-wget \
        curl \
        ca-certificates \
        gnupg2 \
        rsync \
        jq \
        ripgrep \
        fd-find \
        tree \
        unzip \
        zip \
        htop \
        vim-enhanced
      ;;
    zypper)
      printf '%s\n' \
        gcc \
        gcc-c++ \
        make \
        dkms \
        git \
        wget \
        curl \
        ca-certificates \
        gpg2 \
        rsync \
        jq \
        ripgrep \
        fd \
        tree \
        unzip \
        zip \
        htop \
        vim
      ;;
    pacman)
      printf '%s\n' \
        gcc \
        make \
        dkms \
        git \
        wget \
        curl \
        ca-certificates \
        gnupg \
        rsync \
        jq \
        ripgrep \
        fd \
        tree \
        unzip \
        zip \
        htop \
        vim
      ;;
  esac
}

base_tool_header_candidates() {
  case "$PKG_MANAGER" in
    apt-get)
      printf '%s\n' "linux-headers-$(uname -r)"
      ;;
    dnf)
      printf '%s\n' "kernel-devel-$(uname -r)" kernel-headers
      ;;
    zypper)
      printf '%s\n' kernel-default-devel
      ;;
    pacman)
      printf '%s\n' linux-headers
      ;;
  esac
}

join_lines_csv() {
  tr '\n' ',' | sed 's/,$//' | sed 's/,/, /g'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)
      APPLY=0
      ;;
    --apply)
      APPLY=1
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

if [[ "$APPLY" -ne 1 ]]; then
  local_header_candidates="$(base_tool_header_candidates | join_lines_csv)"
  cat <<EOF
This was a check run. The script would:
  1. Refresh package metadata via $(package_manager_label "$PKG_MANAGER")
  2. Try to install kernel headers when available: ${local_header_candidates}
  3. Install base packages: $(base_tool_packages | join_lines_csv)

Run with --apply to execute.
EOF
  exit 0
fi

ensure_sudo_session

info "[1/2] Refresh package metadata via $(package_manager_label "$PKG_MANAGER")"
refresh_package_metadata

PACKAGES=()
while IFS= read -r pkg; do
  [[ -n "$pkg" ]] || continue
  if package_available "$pkg" "$PKG_MANAGER"; then
    PACKAGES+=("$pkg")
  else
    warn "Package not available via $(package_manager_label "$PKG_MANAGER"), skipped: $pkg"
  fi
done < <(base_tool_packages)

while IFS= read -r header_pkg; do
  [[ -n "$header_pkg" ]] || continue
  if package_available "$header_pkg" "$PKG_MANAGER"; then
    PACKAGES=("$header_pkg" "${PACKAGES[@]}")
    break
  fi
  warn "Kernel header package not available via $(package_manager_label "$PKG_MANAGER"), skipped: $header_pkg"
done < <(base_tool_header_candidates)

[[ "${#PACKAGES[@]}" -gt 0 ]] || die "No base tool packages were available for $(package_manager_label "$PKG_MANAGER")."

info "[2/2] Install base tools"
install_packages "${PACKAGES[@]}"
