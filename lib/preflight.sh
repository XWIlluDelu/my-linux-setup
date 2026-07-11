#!/usr/bin/env bash

# Read-only setup and update preflight checks.

declare -a PREFLIGHT_LINES=()
PREFLIGHT_ERRORS=0
PREFLIGHT_WARNINGS=0

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
