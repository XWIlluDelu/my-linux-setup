#!/usr/bin/env bash

set -euo pipefail

APPLY="${APPLY:-0}"
declare -a MIRROR_PREFIXES=()
declare -a PREFLIGHT_LINES=()
PREFLIGHT_ERRORS=0
PREFLIGHT_WARNINGS=0

info() {
  printf '[INFO] %s\n' "$*"
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}

die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

quote_cmd() {
  local out=()
  local arg
  for arg in "$@"; do
    out+=("$(printf '%q' "$arg")")
  done
  printf '%s' "${out[*]}"
}

run() {
  if [[ "$APPLY" -eq 1 ]]; then
    info "+ $(quote_cmd "$@")"
    "$@"
    return
  fi

  info "[dry-run] $(quote_cmd "$@")"
}

run_as_root() {
  if [[ "$EUID" -eq 0 ]]; then
    run "$@"
  else
    run sudo "$@"
  fi
}

try_run() {
  if [[ "$APPLY" -eq 1 ]]; then
    info "+ $(quote_cmd "$@")"
    "$@" || warn "Command failed, continuing: $(quote_cmd "$@")"
    return
  fi

  info "[dry-run] $(quote_cmd "$@")"
}

try_run_as_root() {
  if [[ "$EUID" -eq 0 ]]; then
    try_run "$@"
  else
    try_run sudo "$@"
  fi
}

ensure_sudo_session() {
  if [[ "$EUID" -ne 0 ]]; then
    if ! sudo -n true >/dev/null 2>&1; then
      sudo -v
    fi
    sudo_keepalive_start
  fi
}

sudo_keepalive_start() {
  local interval parent_pid

  if [[ "$EUID" -eq 0 ]]; then
    return 0
  fi

  if [[ "${LINUX_SETUP_SUDO_KEEPALIVE_ACTIVE:-0}" == "1" ]]; then
    return 0
  fi

  interval=30
  parent_pid="$BASHPID"
  export LINUX_SETUP_SUDO_KEEPALIVE_ACTIVE=1

  (
    while kill -0 "$parent_pid" 2>/dev/null; do
      sudo -n true >/dev/null 2>&1 || exit 0
      sleep "$interval"
    done
  ) >/dev/null 2>&1 &
}

ensure_command() {
  command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

resolve_target_user() {
  printf '%s\n' "${1:-${LINUX_SETUP_TARGET_USER:-${SUDO_USER:-$(id -un)}}}"
}

resolve_target_home() {
  local target_user home_path
  target_user="${1:-$(resolve_target_user)}"

  home_path="$(getent passwd "$target_user" 2>/dev/null | cut -d: -f6 || true)"
  if [[ -z "$home_path" ]]; then
    home_path="$(awk -F: -v user="$target_user" '$1 == user { print $6 }' /etc/passwd 2>/dev/null || true)"
  fi
  if [[ -z "$home_path" ]]; then
    home_path="${HOME:-}"
  fi

  [[ -n "$home_path" ]] || die "Could not determine the home directory for user '$target_user'."
  printf '%s\n' "$home_path"
}

run_as_target_user() {
  local target_user target_home
  target_user="$1"
  target_home="$2"
  shift 2

  if [[ "$(id -un)" == "$target_user" ]]; then
    env HOME="$target_home" USER="$target_user" "$@"
  else
    sudo -u "$target_user" env HOME="$target_home" USER="$target_user" "$@"
  fi
}

has_interactive_tty() {
  [[ -t 0 && -t 1 ]]
}

has_interactive_input_tty() {
  [[ -t 0 ]]
}

supports_whiptail_ui() {
  if [[ "${LINUX_SETUP_NO_WHIPTAIL:-0}" == "1" ]]; then
    return 1
  fi

  has_interactive_tty || return 1
  command_exists whiptail || return 1

  [[ -n "${TERM:-}" ]] || return 1
  [[ "${TERM:-}" != "dumb" ]] || return 1

  if [[ "${LINUX_SETUP_FORCE_WHIPTAIL:-0}" == "1" ]]; then
    return 0
  fi

  if command_exists tput; then
    local cols lines
    cols=$(tput cols 2>/dev/null || echo 0)
    lines=$(tput lines 2>/dev/null || echo 0)
    [[ "$cols" -ge 60 && "$lines" -ge 16 ]] || return 1
  fi

  return 0
}

prompt_bool_text() {
  local __var_name prompt default answer
  __var_name="$1"
  prompt="$2"
  default="$3"

  while true; do
    if [[ "$default" -eq 1 ]]; then
      printf '%s' "$prompt [Y/n]: " >&2
    else
      printf '%s' "$prompt [y/N]: " >&2
    fi
    read -r answer
    case "$answer" in
      '')
        printf -v "$__var_name" '%s' "$default"
        return 0
        ;;
      y|Y|yes|YES)
        printf -v "$__var_name" '1'
        return 0
        ;;
      n|N|no|NO)
        printf -v "$__var_name" '0'
        return 0
        ;;
      *)
        printf 'Please answer y or n.\n' >&2
        ;;
    esac
  done
}

as_root() {
  if [[ "$EUID" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

detect_os_release() {
  DISTRO_ID="unknown"
  DISTRO_PRETTY="unknown"

  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    DISTRO_ID="${ID:-unknown}"
    DISTRO_PRETTY="${PRETTY_NAME:-$DISTRO_ID}"
  fi
}

preflight_reset() {
  PREFLIGHT_LINES=()
  PREFLIGHT_ERRORS=0
  PREFLIGHT_WARNINGS=0
}

preflight_record() {
  local level message
  level="$1"
  message="$2"

  PREFLIGHT_LINES+=("${level}|${message}")

  case "$level" in
    ok)
      ;;
    warn)
      PREFLIGHT_WARNINGS=$((PREFLIGHT_WARNINGS + 1))
      ;;
    fail)
      PREFLIGHT_ERRORS=$((PREFLIGHT_ERRORS + 1))
      ;;
  esac
}

preflight_ok() {
  preflight_record ok "$1"
}

preflight_warn() {
  preflight_record warn "$1"
}

preflight_fail() {
  preflight_record fail "$1"
}

preflight_print_report() {
  local entry level message

  info "Preflight results:"
  for entry in "${PREFLIGHT_LINES[@]}"; do
    IFS='|' read -r level message <<< "$entry"
    case "$level" in
      ok)
        printf '[OK] %s\n' "$message"
        ;;
      warn)
        printf '[WARN] %s\n' "$message"
        ;;
      fail)
        printf '[FAIL] %s\n' "$message"
        ;;
    esac
  done

  if [[ "$PREFLIGHT_ERRORS" -gt 0 ]]; then
    warn "Preflight failed with ${PREFLIGHT_ERRORS} error(s) and ${PREFLIGHT_WARNINGS} warning(s)."
  elif [[ "$PREFLIGHT_WARNINGS" -gt 0 ]]; then
    warn "Preflight passed with ${PREFLIGHT_WARNINGS} warning(s)."
  else
    info "Preflight checks passed without warnings."
  fi
}

preflight_has_errors() {
  [[ "$PREFLIGHT_ERRORS" -gt 0 ]]
}

apt_lock_holders() {
  local path output found=0
  local lock_files=(
    /var/lib/dpkg/lock-frontend
    /var/lib/dpkg/lock
    /var/cache/apt/archives/lock
    /var/lib/apt/lists/lock
  )

  if command_exists fuser; then
    for path in "${lock_files[@]}"; do
      output="$(fuser "$path" 2>/dev/null || true)"
      if [[ -n "$output" ]]; then
        printf '%s: %s\n' "$path" "$output"
        found=1
      fi
    done
    [[ "$found" -eq 1 ]] && return 0
    return 1
  fi

  if command_exists lsof; then
    for path in "${lock_files[@]}"; do
      output="$(lsof "$path" 2>/dev/null | awk 'NR > 1 {print $1 " pid=" $2}' || true)"
      if [[ -n "$output" ]]; then
        printf '%s: %s\n' "$path" "$output"
        found=1
      fi
    done
    [[ "$found" -eq 1 ]] && return 0
    return 1
  fi

  return 2
}

url_reachable() {
  local url timeout
  url="$1"
  timeout="${NETWORK_CHECK_TIMEOUT:-8}"

  if command_exists curl; then
    curl -fsIL --max-time "$timeout" "$url" >/dev/null 2>&1
    return $?
  fi

  if command_exists wget; then
    wget -q --spider --timeout="$timeout" "$url" >/dev/null 2>&1
    return $?
  fi

  if command_exists python3; then
    python3 - "$url" "$timeout" <<'PY' >/dev/null 2>&1
import sys
import urllib.request

url = sys.argv[1]
timeout = float(sys.argv[2])

req = urllib.request.Request(url, method="HEAD")
with urllib.request.urlopen(req, timeout=timeout):
    pass
PY
    return $?
  fi

  return 2
}

preflight_check_supported_apt_distro() {
  detect_os_release

  if ! command_exists apt-get; then
    preflight_fail "apt-get is required, but it is not available on this system."
    return
  fi

  case "${DISTRO_ID:-unknown}" in
    ubuntu|debian)
      preflight_ok "Detected supported distro: ${DISTRO_PRETTY}"
      ;;
    *)
      preflight_fail "Detected unsupported distro '${DISTRO_PRETTY}'. This workflow currently targets Debian/Ubuntu."
      ;;
  esac
}

preflight_check_supported_package_manager() {
  local pm

  if pm="$(detect_pkg_manager 2>/dev/null)"; then
    preflight_ok "Detected supported package manager: $(package_manager_label "$pm")"
  else
    preflight_fail "No supported package manager detected. Supported: apt, dnf, zypper, pacman."
  fi
}

preflight_check_btrfs_root() {
  local fstype
  fstype="$(findmnt -nro FSTYPE / 2>/dev/null || true)"

  if [[ "$fstype" == "btrfs" ]]; then
    preflight_ok "Root filesystem is btrfs."
  else
    preflight_fail "Root filesystem is '${fstype:-unknown}', but this workflow expects btrfs."
  fi
}

preflight_check_sudo_access() {
  if [[ "$EUID" -eq 0 ]]; then
    preflight_ok "Running as root."
    return
  fi

  if ! command_exists sudo; then
    preflight_fail "sudo is required but not installed."
    return
  fi

  if sudo -n true 2>/dev/null; then
    preflight_ok "sudo access is already available without prompting."
    return
  fi

  if ! has_interactive_input_tty; then
    preflight_fail "sudo access requires a password, but no interactive terminal is available."
    return
  fi

  if sudo -v; then
    preflight_ok "sudo access verified."
  else
    preflight_fail "Failed to authenticate sudo."
  fi
}

preflight_check_apt_locks() {
  local holders rc

  if holders="$(apt_lock_holders 2>/dev/null)"; then
    holders="$(printf '%s' "$holders" | tr '\n' '; ' | sed 's/; $//')"
    preflight_fail "Detected active apt/dpkg lock holders: ${holders}"
    return
  else
    rc="$?"
  fi

  case "$rc" in
    1)
      preflight_ok "No active apt/dpkg locks detected."
      ;;
    2)
      preflight_warn "Could not inspect apt/dpkg locks because neither fuser nor lsof is available."
      ;;
    *)
      preflight_warn "Could not determine apt/dpkg lock status."
      ;;
  esac
}

preflight_check_root_free_space() {
  local min_kb warn_kb label available_kb
  min_kb="$1"
  warn_kb="$2"
  label="$3"
  available_kb="$(df -Pk / 2>/dev/null | awk 'NR==2 {print $4}')"

  if [[ -z "$available_kb" ]]; then
    preflight_warn "Could not determine free space for ${label}."
    return
  fi

  if (( available_kb < min_kb )); then
    preflight_fail "${label} requires more free disk space on / (available: ${available_kb} KiB)."
  elif (( available_kb < warn_kb )); then
    preflight_warn "${label} is running with limited free disk space on / (available: ${available_kb} KiB)."
  else
    preflight_ok "${label} has enough free disk space on /."
  fi
}

preflight_check_network_access() {
  local label url rc unsupported=1
  label="$1"
  shift

  for url in "$@"; do
    if url_reachable "$url"; then
      preflight_ok "${label} reachable via ${url}"
      return
    fi
    rc="$?"
    if [[ "$rc" -ne 2 ]]; then
      unsupported=0
    fi
  done

  if [[ "$unsupported" -eq 1 ]]; then
    preflight_warn "Could not probe ${label} because no supported HTTP check tool is available."
  else
    preflight_fail "Could not reach any ${label} endpoint."
  fi
}

preflight_check_optional_network_access() {
  local label url rc unsupported=1
  label="$1"
  shift

  for url in "$@"; do
    if url_reachable "$url"; then
      preflight_ok "${label} reachable via ${url}"
      return
    fi
    rc="$?"
    if [[ "$rc" -ne 2 ]]; then
      unsupported=0
    fi
  done

  if [[ "$unsupported" -eq 1 ]]; then
    preflight_warn "Could not probe ${label} because no supported HTTP check tool is available."
  else
    preflight_warn "Could not reach any ${label} endpoint; the related optional install or update may fail."
  fi
}

grub_preseed_summary() {
  local package key value

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

    if [[ -n "$value" ]]; then
      printf '%s %s=%s\n' "$package" "$key" "${value#, }"
      return 0
    fi
  done

  return 1
}

preflight_check_grub_preseed() {
  local summary

  if ! command_exists debconf-show; then
    preflight_warn "debconf-show is unavailable, so GRUB preseed state could not be checked."
    return
  fi

  if summary="$(grub_preseed_summary)"; then
    preflight_ok "GRUB install target preseed detected: ${summary}"
    return
  fi

  if dpkg_package_installed grub-efi-amd64 || dpkg_package_installed grub-pc; then
    preflight_warn "GRUB is installed, but no existing install_devices debconf value was found."
  else
    preflight_ok "No GRUB install target preseed is needed on this system."
  fi
}

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

download_url_with_speed_guard() {
  local url target_path expected_sha256 tmp_path actual_sha256
  url="$1"
  target_path="$2"
  expected_sha256="${3:-}"

  ensure_command curl
  mkdir -p "$(dirname "$target_path")"

  if [[ -f "$target_path" ]]; then
    if [[ -z "$expected_sha256" ]]; then
      info "No digest available for $url; re-downloading instead of trusting the cached file."
      rm -f "$target_path"
    else
      actual_sha256="$(sha256sum "$target_path" | awk '{print $1}')"
      if [[ "$actual_sha256" == "$expected_sha256" ]]; then
        info "Using existing verified file: $target_path"
        return 0
      fi

      warn "Existing file failed digest verification, re-downloading: $target_path"
      rm -f "$target_path"
    fi
  fi

  tmp_path="${target_path}.part"
  rm -f "$tmp_path"

  info "Downloading from: $url"
  if ! curl \
    -fL \
    --progress-bar \
    --connect-timeout "${DOWNLOAD_CONNECT_TIMEOUT:-5}" \
    --speed-limit "${DOWNLOAD_SPEED_LIMIT:-204800}" \
    --speed-time "${DOWNLOAD_SPEED_TIME:-8}" \
    -o "$tmp_path" \
    "$url"; then
    rm -f "$tmp_path"
    return 1
  fi

  if [[ -n "$expected_sha256" ]]; then
    ensure_command sha256sum
    actual_sha256="$(sha256sum "$tmp_path" | awk '{print $1}')"
    if [[ "$actual_sha256" != "$expected_sha256" ]]; then
      rm -f "$tmp_path"
      warn "Digest mismatch for $url"
      return 1
    fi
  fi

  mv "$tmp_path" "$target_path"
  info "Saved to $target_path"
}

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

record_stage2_result() {
  local step status message
  step="$1"
  status="$2"
  message="${3:-}"

  if [[ -z "${STAGE2_RESULT_LOG:-}" ]]; then
    return 0
  fi

  message="${message//$'\t'/ }"
  message="${message//$'\n'/ }"
  printf '%s\t%s\t%s\n' "$step" "$status" "$message" >> "$STAGE2_RESULT_LOG"
}

require_btrfs_root() {
  local fstype
  fstype="$(findmnt -nro FSTYPE / 2>/dev/null || true)"
  [[ "$fstype" == "btrfs" ]] || die "Root filesystem is '$fstype', not btrfs."
}

current_root_source() {
  findmnt -nro SOURCE /
}

current_root_subvol_path() {
  local root_src root_opts subvol
  root_src="$(current_root_source)"

  if [[ "$root_src" == *'['*']'* ]]; then
    subvol="${root_src#*[}"
    subvol="${subvol%]}"
    subvol="${subvol#/}"
    if [[ "$subvol" == "/" ]]; then
      printf '\n'
    else
      printf '%s\n' "$subvol"
    fi
    return 0
  fi

  root_opts="$(findmnt -nro OPTIONS / 2>/dev/null || true)"
  subvol="$(
    printf '%s\n' "$root_opts" \
      | tr ',' '\n' \
      | awk -F= '$1=="subvol" {print $2; exit}'
  )"
  subvol="${subvol#/}"
  if [[ "$subvol" == "/" ]]; then
    printf '\n'
  else
    printf '%s\n' "$subvol"
  fi
}

stable_root_subvol_path() {
  local root_subvol
  root_subvol="$(current_root_subvol_path)"

  if [[ "$root_subvol" == *"/.snapshots/"* ]]; then
    printf '%s\n' "${root_subvol%%/.snapshots/*}"
    return 0
  fi

  printf '%s\n' "$root_subvol"
}

stable_snapshots_subvol_path() {
  local stable_root_subvol
  stable_root_subvol="$(stable_root_subvol_path)"

  if [[ -n "$stable_root_subvol" ]]; then
    printf '%s/.snapshots\n' "$stable_root_subvol"
  else
    printf '.snapshots\n'
  fi
}

current_root_device() {
  local root_src root_dev
  root_src="$(current_root_source)"
  root_dev="${root_src%%[*}"
  if [[ -b "$root_dev" ]]; then
    readlink -f "$root_dev"
    return 0
  fi

  printf '%s\n' "$root_dev"
}

current_root_uuid() {
  local uuid root_dev link
  uuid="$(findmnt -nro UUID / 2>/dev/null || true)"
  if [[ -n "$uuid" ]]; then
    printf '%s\n' "$uuid"
    return 0
  fi

  root_dev="$(current_root_device)"

  if command_exists lsblk; then
    uuid="$(lsblk -ndo UUID "$root_dev" 2>/dev/null | awk 'NF {print; exit}' || true)"
    if [[ -n "$uuid" ]]; then
      printf '%s\n' "$uuid"
      return 0
    fi
  fi

  if [[ -d /dev/disk/by-uuid ]]; then
    for link in /dev/disk/by-uuid/*; do
      [[ -L "$link" ]] || continue
      if [[ "$(readlink -f "$link")" == "$root_dev" ]]; then
        basename "$link"
        return 0
      fi
    done
  fi

  uuid="$(blkid -s UUID -o value "$root_dev" 2>/dev/null || true)"
  printf '%s\n' "$uuid"
}

normalized_btrfs_opts() {
  local target raw normalized
  target="${1:-/}"
  raw="$(findmnt -nro OPTIONS "$target" 2>/dev/null || true)"
  normalized="$(
    printf '%s\n' "$raw" \
      | tr ',' '\n' \
      | grep -vE '^(subvol=|subvolid=|fsroot=)' \
      | paste -sd, -
  )"

  if [[ -n "$normalized" ]]; then
    printf '%s\n' "$normalized"
  else
    printf 'defaults\n'
  fi
}

with_subvol_opt() {
  local base_opts subvol
  base_opts="$1"
  subvol="$2"

  if [[ -n "$base_opts" ]]; then
    printf '%s,subvol=%s\n' "$base_opts" "$subvol"
  else
    printf 'subvol=%s\n' "$subvol"
  fi
}

systemd_unit_exists() {
  local unit
  unit="$1"

  if ! command -v systemctl >/dev/null 2>&1; then
    return 1
  fi

  systemctl list-unit-files "$unit" --no-legend 2>/dev/null | grep -q "^$unit"
}

enable_unit_if_exists() {
  local unit
  unit="$1"

  if systemd_unit_exists "$unit"; then
    run_as_root systemctl enable --now "$unit"
  else
    warn "systemd unit not found, skipped: $unit"
  fi
}

rebuild_initramfs_if_possible() {
  if command -v update-initramfs >/dev/null 2>&1; then
    run_as_root update-initramfs -u -k all
    return 0
  fi

  if command -v dracut >/dev/null 2>&1; then
    run_as_root dracut -f
    return 0
  fi

  if command -v mkinitcpio >/dev/null 2>&1; then
    run_as_root mkinitcpio -P
    return 0
  fi

  warn "No supported initramfs rebuild command found."
}

disable_grub_btrfs_rootflags_if_possible() {
  local file stamp changed_any=0 backup_dir backup_file

  if ! command_exists python3; then
    warn "python3 is unavailable, so GRUB btrfs rootflags injection could not be disabled."
    return 1
  fi

  for file in /etc/grub.d/10_linux /etc/grub.d/20_linux_xen; do
    [[ -f "$file" ]] || continue

    if ! grep -Fq 'rootflags=subvol=${rootsubvol}' "$file"; then
      continue
    fi

    stamp="$(date +%Y%m%d-%H%M%S)"
    backup_dir="/var/backups/linux-setup-grub"
    backup_file="${backup_dir}/$(basename "$file").linux-setup.bak.${stamp}"
    run_as_root mkdir -p "$backup_dir"
    run_as_root cp -a "$file" "$backup_file"
    run_as_root chmod 0644 "$backup_file"
    run_as_root python3 - "$file" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()
lines = text.splitlines(keepends=True)
out = []
changed = False

for line in lines:
    if 'rootflags=subvol=${rootsubvol}' in line and 'GRUB_CMDLINE_LINUX=' in line and not line.lstrip().startswith('#'):
        indent = line[: len(line) - len(line.lstrip())]
        out.append(
            f"{indent}: # linux-setup: keep btrfs root selection driven by the default subvolume for snapper rollback.\n"
        )
        changed = True
        continue
    out.append(line)

if changed:
    path.write_text(''.join(out))
PY
    changed_any=1
  done

  if [[ "$changed_any" -eq 1 ]]; then
    info "Disabled GRUB btrfs rootflags injection so the default subvolume can drive snapper rollback boots."
  else
    info "No GRUB btrfs rootflags injection was detected."
  fi
}

ensure_grub_saved_default_if_possible() {
  local grub_defaults backup stamp
  grub_defaults="/etc/default/grub"

  [[ -f "$grub_defaults" ]] || return 0

  if grep -Eq '^GRUB_DEFAULT=saved$' "$grub_defaults"; then
    info "GRUB_DEFAULT is already set to 'saved'."
    return 0
  fi

  stamp="$(date +%Y%m%d-%H%M%S)"
  backup="/var/backups/linux-setup-grub/default-grub.bak.${stamp}"
  run_as_root mkdir -p /var/backups/linux-setup-grub
  run_as_root cp -a "$grub_defaults" "$backup"
  run_as_root python3 - "$grub_defaults" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()

if re.search(r'^GRUB_DEFAULT=', text, flags=re.M):
    text = re.sub(r'^GRUB_DEFAULT=.*$', 'GRUB_DEFAULT=saved', text, flags=re.M)
else:
    if not text.endswith('\n'):
        text += '\n'
    text += 'GRUB_DEFAULT=saved\n'

path.write_text(text)
PY
  info "Configured GRUB_DEFAULT=saved so rollback can retarget the boot entry."
}

rebuild_grub_if_possible() {
  if command -v update-grub >/dev/null 2>&1; then
    run_as_root update-grub
    return 0
  fi

  if command -v grub-mkconfig >/dev/null 2>&1; then
    if [[ -d /boot/grub ]]; then
      run_as_root grub-mkconfig -o /boot/grub/grub.cfg
      return 0
    fi

    if [[ -d /boot/grub2 ]]; then
      run_as_root grub-mkconfig -o /boot/grub2/grub.cfg
      return 0
    fi

    warn "grub-mkconfig exists, but no grub.cfg path was detected."
    return 0
  fi

  warn "No supported grub rebuild command found."
}

github_release_api_get() {
  local url
  url="$1"

  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    curl -fsSL \
      -H 'Accept: application/vnd.github+json' \
      -H 'X-GitHub-Api-Version: 2022-11-28' \
      -H 'User-Agent: linux-setup' \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      "$url"
  else
    curl -fsSL \
      -H 'Accept: application/vnd.github+json' \
      -H 'X-GitHub-Api-Version: 2022-11-28' \
      -H 'User-Agent: linux-setup' \
      "$url"
  fi
}

github_release_parse_latest() {
  local repo asset_regex tag_strip_prefix assignments
  repo="$1"
  asset_regex="$2"
  tag_strip_prefix="${3:-}"

  ensure_command curl
  ensure_command python3

  if assignments="$(
    github_release_api_get "https://api.github.com/repos/${repo}/releases/latest" \
      | python3 -c '
import json
import re
import shlex
import sys

asset_regex = re.compile(sys.argv[1])
tag_strip_prefix = sys.argv[2]
data = json.load(sys.stdin)

asset = None
for current in data.get("assets", []):
    name = current.get("name", "")
    url = current.get("browser_download_url", "")
    if asset_regex.search(name) or asset_regex.search(url):
        asset = current
        break

if asset is None:
    raise SystemExit(2)

tag = data.get("tag_name", "")
version = tag[len(tag_strip_prefix):] if tag_strip_prefix and tag.startswith(tag_strip_prefix) else tag
digest = asset.get("digest", "")
if digest.startswith("sha256:"):
    digest = digest.split(":", 1)[1]

fields = {
    "GITHUB_RELEASE_TAG": tag,
    "GITHUB_RELEASE_VERSION": version,
    "GITHUB_RELEASE_URL": data.get("html_url", ""),
    "GITHUB_RELEASE_PUBLISHED_AT": data.get("published_at", ""),
    "GITHUB_ASSET_NAME": asset.get("name", ""),
    "GITHUB_ASSET_URL": asset.get("browser_download_url", ""),
    "GITHUB_ASSET_DIGEST": digest,
}

for key, value in fields.items():
    print(f"{key}={shlex.quote(value)}")
' "$asset_regex" "$tag_strip_prefix"
  )"; then
    :
  else
    if ! assignments="$(
      python3 - "$repo" "$asset_regex" "$tag_strip_prefix" <<'PY'
import html
import re
import shlex
import subprocess
import sys

repo = sys.argv[1]
asset_regex = re.compile(sys.argv[2])
tag_strip_prefix = sys.argv[3]
latest_url = f"https://github.com/{repo}/releases/latest"

def curl(*args):
    return subprocess.check_output(
        ["curl", "-fsSL", "-A", "linux-setup", *args],
        universal_newlines=True,
    )

release_url = curl("-o", "/dev/null", "-w", "%{url_effective}", latest_url).strip()
if not release_url:
    raise SystemExit(1)

tag = release_url.rstrip("/").rsplit("/", 1)[-1]
html_doc = curl(release_url)

asset = None
for href in re.findall(r'href="([^"]+)"', html_doc):
    href = html.unescape(href)
    if href.startswith("/"):
        full_url = "https://github.com" + href
    else:
        full_url = href
    if f"/{repo}/releases/download/" not in full_url:
        continue
    name = full_url.rsplit("/", 1)[-1]
    if asset_regex.search(name) or asset_regex.search(full_url):
        asset = {"name": name, "url": full_url}
        break

if asset is None:
    raise SystemExit(2)

version = tag[len(tag_strip_prefix):] if tag_strip_prefix and tag.startswith(tag_strip_prefix) else tag
fields = {
    "GITHUB_RELEASE_TAG": tag,
    "GITHUB_RELEASE_VERSION": version,
    "GITHUB_RELEASE_URL": release_url,
    "GITHUB_RELEASE_PUBLISHED_AT": "",
    "GITHUB_ASSET_NAME": asset["name"],
    "GITHUB_ASSET_URL": asset["url"],
    "GITHUB_ASSET_DIGEST": "",
}

for key, value in fields.items():
    print(f"{key}={shlex.quote(value)}")
PY
    )"; then
      warn "Could not parse latest release metadata for ${repo}"
      return 1
    fi
  fi

  while IFS='=' read -r __key __val; do
    [[ -n "$__key" ]] || continue
    # Strip surrounding single quotes produced by shlex.quote()
    __val="${__val#\'}" ; __val="${__val%\'}"
    printf -v "$__key" '%s' "$__val"
  done <<< "$assignments"
}

github_release_append_default_mirrors() {
  if [[ "${GITHUB_RELEASE_NO_DEFAULT_MIRRORS:-0}" == "1" ]]; then
    return
  fi

  if [[ -z "${GITHUB_MIRROR_PREFIXES:-}" && "${#MIRROR_PREFIXES[@]}" -eq 0 ]]; then
    MIRROR_PREFIXES+=(
      "https://gh-proxy.com/"
      "https://gh.dlproxy.workers.dev/"
      "https://ghproxy.vip/"
      "https://gh.llkk.cc/"
    )
  fi
}

github_release_append_env_mirrors() {
  local raw prefix
  raw="${GITHUB_MIRROR_PREFIXES:-}"
  raw="${raw//$'\n'/ }"
  raw="${raw//,/ }"

  for prefix in $raw; do
    MIRROR_PREFIXES+=("$prefix")
  done
}

github_release_normalize_prefix() {
  local prefix
  prefix="$1"

  if [[ -z "$prefix" ]]; then
    printf '\n'
    return
  fi

  if [[ "$prefix" == */ ]]; then
    printf '%s\n' "$prefix"
  else
    printf '%s/\n' "$prefix"
  fi
}

github_release_build_candidate_urls() {
  local asset_url prefix normalized
  asset_url="$1"
  declare -g -a DOWNLOAD_CANDIDATE_URLS=()
  declare -A seen_urls=()

  DOWNLOAD_CANDIDATE_URLS+=("$asset_url")
  seen_urls["$asset_url"]=1

  github_release_append_env_mirrors
  github_release_append_default_mirrors

  for prefix in "${MIRROR_PREFIXES[@]}"; do
    normalized="$(github_release_normalize_prefix "$prefix")"
    [[ -n "$normalized" ]] || continue
    if [[ -z "${seen_urls["${normalized}${asset_url}"]+x}" ]]; then
      DOWNLOAD_CANDIDATE_URLS+=("${normalized}${asset_url}")
      seen_urls["${normalized}${asset_url}"]=1
    fi
  done
}

github_release_verify_sha256() {
  local file_path expected_sha256 actual_sha256
  file_path="$1"
  expected_sha256="$2"

  if [[ -z "$expected_sha256" ]]; then
    return 0
  fi

  ensure_command sha256sum
  actual_sha256="$(sha256sum "$file_path" | awk '{print $1}')"
  [[ "$actual_sha256" == "$expected_sha256" ]]
}

github_release_download_asset() {
  local asset_url expected_sha256 target_path tmp_path candidate_url speed_limit speed_time
  asset_url="$1"
  expected_sha256="$2"
  target_path="$3"

  mkdir -p "$(dirname "$target_path")"

  if [[ -f "$target_path" ]]; then
    if github_release_verify_sha256 "$target_path" "$expected_sha256"; then
      info "Using existing verified file: $target_path"
      return
    fi
    warn "Existing file failed digest verification, re-downloading: $target_path"
    rm -f "$target_path"
  fi

  tmp_path="${target_path}.part"
  github_release_build_candidate_urls "$asset_url"
  speed_limit="${GITHUB_DOWNLOAD_SPEED_LIMIT:-204800}"
  speed_time="${GITHUB_DOWNLOAD_SPEED_TIME:-8}"

  for candidate_url in "${DOWNLOAD_CANDIDATE_URLS[@]}"; do
    rm -f "$tmp_path"
    info "Downloading from: $candidate_url"
    if ! curl \
      -fL \
      --progress-bar \
      --connect-timeout "${GITHUB_DOWNLOAD_CONNECT_TIMEOUT:-5}" \
      --speed-limit "$speed_limit" \
      --speed-time "$speed_time" \
      -o "$tmp_path" \
      "$candidate_url"; then
      warn "Download failed or stayed below ${speed_limit}B/s for ${speed_time}s, trying next candidate"
      rm -f "$tmp_path"
      continue
    fi

    if ! github_release_verify_sha256 "$tmp_path" "$expected_sha256"; then
      warn "Digest mismatch, discarded: $candidate_url"
      rm -f "$tmp_path"
      continue
    fi

    mv "$tmp_path" "$target_path"
    info "Saved to $target_path"
    return
  done

  warn "All download candidates failed for $asset_url"
  return 1
}
