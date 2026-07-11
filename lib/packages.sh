#!/usr/bin/env bash

# Package-manager and distro package operations.

apt_noninteractive() {
  ensure_command apt-get

  if [[ "$EUID" -eq 0 ]]; then
    env \
      DEBIAN_FRONTEND=noninteractive \
      UCF_FORCE_CONFOLD=1 \
      apt-get \
      -o Dpkg::Options::=--force-confdef \
      -o Dpkg::Options::=--force-confold \
      "$@"
  else
    sudo env \
      DEBIAN_FRONTEND=noninteractive \
      UCF_FORCE_CONFOLD=1 \
      apt-get \
      -o Dpkg::Options::=--force-confdef \
      -o Dpkg::Options::=--force-confold \
      "$@"
  fi
}
dpkg_package_installed() {
  command_exists dpkg-query || return 1
  dpkg-query -W -f='${Status}\n' "$1" 2>/dev/null | grep -q 'install ok installed'
}
linux_setup_package_arch() {
  local machine_arch

  if command_exists dpkg; then
    dpkg --print-architecture
    return 0
  fi

  machine_arch="$(uname -m)"
  case "$machine_arch" in
    x86_64|amd64)
      printf 'amd64\n'
      ;;
    aarch64|arm64)
      printf 'arm64\n'
      ;;
    ppc64le|ppc64el)
      printf 'ppc64el\n'
      ;;
    *)
      printf '%s\n' "$machine_arch"
      ;;
  esac
}
package_available() {
  local package_name pm
  package_name="$1"
  pm="${2:-$(detect_pkg_manager 2>/dev/null || true)}"

  case "$pm" in
    apt-get)
      command_exists apt-cache || return 1
      apt-cache show "$package_name" >/dev/null 2>&1
      ;;
    dnf)
      command_exists dnf || return 1
      dnf -q info "$package_name" >/dev/null 2>&1
      ;;
    zypper)
      command_exists zypper || return 1
      zypper --quiet info "$package_name" >/dev/null 2>&1
      ;;
    pacman)
      command_exists pacman || return 1
      pacman -Si "$package_name" >/dev/null 2>&1
      ;;
    *)
      return 1
      ;;
  esac
}
detect_pkg_manager() {
  local candidate
  for candidate in apt-get dnf zypper pacman; do
    if command -v "$candidate" >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}
package_manager_label() {
  local pm
  pm="${1:-$(detect_pkg_manager 2>/dev/null || true)}"

  case "$pm" in
    apt-get)
      printf 'apt\n'
      ;;
    dnf|zypper|pacman)
      printf '%s\n' "$pm"
      ;;
    *)
      printf 'supported package manager\n'
      ;;
  esac
}
supports_debian_apt_workflow() {
  local pm
  pm="${1:-$(detect_pkg_manager 2>/dev/null || true)}"

  [[ "$pm" == "apt-get" ]] || return 1
  detect_os_release
  [[ "${DISTRO_ID:-unknown}" == "ubuntu" || "${DISTRO_ID:-unknown}" == "debian" ]]
}
prepare_pacman_keyring() {
  as_root pacman -Sy --needed --noconfirm archlinux-keyring
}
refresh_package_metadata() {
  local pm
  pm="$(detect_pkg_manager)" || die "No supported package manager detected. Supported: apt, dnf, zypper, pacman."

  case "$pm" in
    apt-get)
      apt_noninteractive update
      ;;
    dnf)
      as_root dnf makecache
      ;;
    zypper)
      as_root zypper refresh
      ;;
    pacman)
      prepare_pacman_keyring
      as_root pacman -Sy --noconfirm
      ;;
    *)
      die "Unsupported package manager: $pm"
      ;;
  esac
}
full_system_upgrade() {
  local pm
  pm="$(detect_pkg_manager)" || die "No supported package manager detected. Supported: apt, dnf, zypper, pacman."

  case "$pm" in
    apt-get)
      apt_noninteractive full-upgrade -y
      ;;
    dnf)
      as_root dnf upgrade -y
      ;;
    zypper)
      as_root zypper update -y
      ;;
    pacman)
      prepare_pacman_keyring
      as_root pacman -Syu --noconfirm
      ;;
    *)
      die "Unsupported package manager: $pm"
      ;;
  esac
}
install_packages() {
  local pm
  pm="$(detect_pkg_manager)" || {
    warn "No supported package manager detected. Please install manually: $*"
    return 0
  }

  case "$pm" in
    apt-get)
      apt_noninteractive update
      apt_noninteractive install -y "$@"
      ;;
    dnf)
      as_root dnf install -y "$@"
      ;;
    zypper)
      as_root zypper install -y "$@"
      ;;
    pacman)
      prepare_pacman_keyring
      as_root pacman -Sy --needed --noconfirm "$@"
      ;;
    *)
      die "Unsupported package manager: $pm"
      ;;
  esac
}
remove_unused_packages() {
  local pm
  local -a orphaned_packages
  pm="$(detect_pkg_manager)" || die "No supported package manager detected. Supported: apt, dnf, zypper, pacman."

  case "$pm" in
    apt-get)
      apt_noninteractive autoremove -y --purge
      ;;
    dnf)
      as_root dnf autoremove -y
      ;;
    zypper)
      info "Automatic removal of unneeded packages is not implemented for zypper; skipped."
      ;;
    pacman)
      mapfile -t orphaned_packages < <(pacman -Qtdq 2>/dev/null || true)
      if [[ "${#orphaned_packages[@]}" -gt 0 ]]; then
        as_root pacman -Rns --noconfirm "${orphaned_packages[@]}"
      else
        info "No orphaned pacman packages detected."
      fi
      ;;
    *)
      die "Unsupported package manager: $pm"
      ;;
  esac
}
clean_package_caches() {
  local pm
  pm="$(detect_pkg_manager)" || die "No supported package manager detected. Supported: apt, dnf, zypper, pacman."

  case "$pm" in
    apt-get)
      apt_noninteractive autoclean -y
      apt_noninteractive clean
      ;;
    dnf)
      as_root dnf clean all
      ;;
    zypper)
      as_root zypper clean --all
      ;;
    pacman)
      as_root pacman -Scc --noconfirm
      ;;
    *)
      die "Unsupported package manager: $pm"
      ;;
  esac
}
purge_residual_config_packages() {
  local pm
  local -a rc_packages
  pm="$(detect_pkg_manager)" || die "No supported package manager detected. Supported: apt, dnf, zypper, pacman."

  case "$pm" in
    apt-get)
      ensure_command dpkg
      ensure_command awk
      mapfile -t rc_packages < <(dpkg -l | awk '/^rc/ {print $2}')
      if [[ "${#rc_packages[@]}" -gt 0 ]]; then
        apt_noninteractive purge -y "${rc_packages[@]}"
      else
        info "No residual config packages detected."
      fi
      ;;
    *)
      info "Residual config package purge is only defined for apt/dpkg systems; skipped."
      ;;
  esac
}
check_reboot_requirement() {
  local rc

  if [[ -f /var/run/reboot-required ]]; then
    return 0
  fi

  if command_exists needs-restarting; then
    needs-restarting -r >/dev/null 2>&1
    rc="$?"
    case "$rc" in
      0)
        return 1
        ;;
      1)
        return 0
        ;;
      *)
        return 2
        ;;
    esac
  fi

  return 1
}
preseed_grub_if_possible() {
  local package key value prefixed_value

  if ! command_exists debconf-show || ! command_exists debconf-set-selections; then
    warn "debconf tools not found; skipped GRUB preseed."
    return 0
  fi

  for package in grub-efi-amd64 grub-pc; do
    if ! dpkg_package_installed "$package"; then
      continue
    fi

    case "$package" in
      grub-efi-amd64)
        key="grub-efi/install_devices"
        ;;
      grub-pc)
        key="grub-pc/install_devices"
        ;;
      *)
        continue
        ;;
    esac

    value="$(
      debconf-show "$package" 2>/dev/null \
        | awk -v key="$key" '
            {
              line = $0
              sub(/^[* ]*/, "", line)
              prefix = key ": "
              if (index(line, prefix) == 1) {
                print substr(line, length(prefix) + 1)
                exit
              }
            }
          '
    )"

    if [[ -z "$value" ]]; then
      warn "No existing debconf value found for ${package} ${key}; GRUB prompt may still appear on some systems."
      continue
    fi

    prefixed_value="${value#, }"
    printf '%s %s multiselect %s\n' "$package" "$key" "$prefixed_value" | as_root debconf-set-selections
    info "Preseeded ${package} ${key}: ${prefixed_value}"

    if [[ "$package" == "grub-efi-amd64" ]]; then
      printf 'grub2 grub2/update_nvram boolean true\n' | as_root debconf-set-selections
      info "Preseeded grub2/update_nvram=true"
    fi
  done
}
