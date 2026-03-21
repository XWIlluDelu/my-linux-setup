#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
source "$ROOT_DIR/lib/common.sh"

RUN_MODE="check"
ASSUME_YES=0
METADATA_JSON=""

INSTALL_METHOD=""
CUDA_CHOICE=""
DRIVER_BRANCH=""
DRIVER_SELECTION_MODE=""
LOCK_DRIVER_BRANCH=0
INSTALL_TOOLKIT=0
RESOLVED_CUDA_FAMILY=""
ALLOW_UNSUPPORTED_CUDA_REPO=0

SYSTEM_PRETTY_NAME=""
SYSTEM_ID=""
SYSTEM_VERSION_ID=""
SYSTEM_ARCH=""
SYSTEM_CURRENT_REPO_ID=""
SYSTEM_CURRENT_REPO_SUPPORTED=0
SYSTEM_PREFERRED_REPO_ID=""
SYSTEM_PREFERRED_REPO_SUPPORTED=0
SYSTEM_SUPPORTED_REPO_IDS=""
SYSTEM_SECURE_BOOT="unknown"

GPU_NAME=""
GPU_CURRENT_DRIVER_VERSION=""
GPU_INSTALLED_BRANCH=""
GPU_RECOMMENDED_BRANCH=""
CUDA_LATEST_RELEASE=""
NVIDIA_PACKAGE_REGEX='^(nvidia-|libnvidia-|cuda-|nsight-|xserver-xorg-video-nvidia-|linux-(modules|objects)-nvidia-)'

GRAPHICAL_SESSION_ACTIVE=0
DISPLAY_MANAGER_ACTIVE=0
DISPLAY_MANAGER_UNIT=""
LOADED_NVIDIA_MODULES=""

declare -a APT_NVIDIA_PACKAGES=()
declare -a HELD_NVIDIA_PACKAGES=()
declare -a RUNFILE_DRIVER_MARKERS=()

restore_tty_after_whiptail() {
  stty sane 2>/dev/null || true
  tput sgr0 2>/dev/null || true
  tput cnorm 2>/dev/null || true
}

cleanup() {
  if [[ -n "${METADATA_JSON:-}" && -f "${METADATA_JSON:-}" ]]; then
    rm -f "$METADATA_JSON"
  fi
}
trap cleanup EXIT

declare -a DRIVER_BRANCHES=()
declare -A DRIVER_CANDIDATE_VERSION=()
declare -A DRIVER_RECOMMENDED=()
declare -A DRIVER_INSTALLED=()
declare -A DRIVER_BEST_CUDA=()
declare -A DRIVER_COMPATIBLE_CUDA=()

declare -a CUDA_FAMILIES=()
declare -A CUDA_LABEL=()
declare -A CUDA_RELEASE=()
declare -A CUDA_MIN_DRIVER=()
declare -A CUDA_PACKAGE_NAME=()
declare -A CUDA_PACKAGE_VERSION=()
declare -A CUDA_RUNFILE_URL=()
declare -A CUDA_RUNFILE_FILENAME=()
declare -A CUDA_RUNFILE_MD5=()
declare -A CUDA_COMPATIBLE_DRIVERS=()

usage() {
  cat <<'EOF'
Interactive NVIDIA installer.

Usage:
  install-nvidia-cuda.sh --check
  install-nvidia-cuda.sh --apply [--yes]

Modes:
  --check   Probe official NVIDIA metadata and print the available choices (default)
  --apply   Run the interactive installer
  --yes     Accept the script defaults in apply mode

Behavior:
  - The package-managed path installs a specific open driver branch, can lock that branch, and optionally installs `cuda-toolkit-X-Y`.
  - The runfile path downloads the selected CUDA runfile and hands control to NVIDIA's official installer, which may replace the current driver with a proprietary one.
  - The preview-only path resolves packages and links without making changes.
EOF
}

join_by() {
  local delimiter out value
  delimiter="$1"
  shift || true
  out=""
  for value in "$@"; do
    if [[ -n "$out" ]]; then
      out+="$delimiter"
    fi
    out+="$value"
  done
  printf '%s\n' "$out"
}

bool_word() {
  if [[ "$1" -eq 1 ]]; then
    printf 'yes\n'
  else
    printf 'no\n'
  fi
}

install_method_label() {
  case "$1" in
    deb) printf 'package-managed\n' ;;
    run) printf 'runfile\n' ;;
    manual) printf 'preview-only\n' ;;
    *) printf '%s\n' "$1" ;;
  esac
}

summarize_items() {
  local max_count summary
  max_count="$1"
  shift || true

  if [[ "$#" -eq 0 ]]; then
    printf 'none\n'
    return 0
  fi

  if [[ "$#" -le "$max_count" ]]; then
    join_by , "$@"
    return 0
  fi

  summary="$(join_by , "${@:1:$max_count}")"
  printf '%s,...(+%d more)\n' "$summary" "$(($# - max_count))"
}

branch_display_label() {
  local branch label
  branch="$1"
  label="${branch}-open"
  if [[ "${DRIVER_INSTALLED[$branch]:-0}" == "1" ]]; then
    label+=" [installed]"
  fi
  if [[ "${DRIVER_RECOMMENDED[$branch]:-0}" == "1" ]]; then
    label+=" [recommended]"
  fi
  label+=" -> best CUDA ${DRIVER_BEST_CUDA[$branch]:-n/a}"
  printf '%s\n' "$label"
}

cuda_display_label() {
  local family
  family="$1"
  printf '%s (%s, min driver %s)\n' "$family" "${CUDA_LABEL[$family]}" "${CUDA_MIN_DRIVER[$family]}"
}

choose_one_text() {
  local __var_name prompt default_value answer choice line value label desc idx
  __var_name="$1"
  prompt="$2"
  default_value="$3"
  shift 3

  while true; do
    printf '%s\n' "$prompt" >&2
    idx=1
    for line in "$@"; do
      IFS='|' read -r value label desc <<< "$line"
      if [[ "$value" == "$default_value" ]]; then
        printf '  %d) %s [default]\n' "$idx" "$label" >&2
      else
        printf '  %d) %s\n' "$idx" "$label" >&2
      fi
      if [[ -n "${desc:-}" ]]; then
        printf '     %s\n' "$desc" >&2
      fi
      idx=$((idx + 1))
    done
    printf 'Choose [%s]: ' "$default_value" >&2
    read -r answer
    if [[ -z "$answer" ]]; then
      printf -v "$__var_name" '%s' "$default_value"
      return 0
    fi
    if [[ "$answer" =~ ^[0-9]+$ ]]; then
      idx=1
      for line in "$@"; do
        if [[ "$idx" -eq "$answer" ]]; then
          IFS='|' read -r value _ <<< "$line"
          printf -v "$__var_name" '%s' "$value"
          return 0
        fi
        idx=$((idx + 1))
      done
    fi
    for line in "$@"; do
      IFS='|' read -r value _ <<< "$line"
      if [[ "$answer" == "$value" ]]; then
        printf -v "$__var_name" '%s' "$value"
        return 0
      fi
    done
    printf 'Please choose a valid option.\n' >&2
  done
}

choose_one_whiptail() {
  local __var_name title prompt default_value choice line value label desc status
  __var_name="$1"
  title="$2"
  prompt="$3"
  default_value="$4"
  shift 4

  local -a args=()
  for line in "$@"; do
    IFS='|' read -r value label desc <<< "$line"
    if [[ "$value" == "$default_value" ]]; then
      status="ON"
    else
      status="OFF"
    fi
    if [[ -n "${desc:-}" ]]; then
      label+=" - ${desc}"
    fi
    args+=("$value" "$label" "$status")
  done

  choice="$(
    whiptail \
      --title "$title" \
      --radiolist "$prompt" \
      22 96 12 \
      "${args[@]}" \
      3>&1 1>&2 2>&3
  )" || die "Selection cancelled."
  restore_tty_after_whiptail
  printf -v "$__var_name" '%s' "$choice"
}

choose_one() {
  local __var_name title prompt default_value
  __var_name="$1"
  title="$2"
  prompt="$3"
  default_value="$4"
  shift 4
  if supports_whiptail_ui; then
    choose_one_whiptail "$__var_name" "$title" "$prompt" "$default_value" "$@"
  else
    choose_one_text "$__var_name" "$prompt" "$default_value" "$@"
  fi
}

probe_metadata() {
  METADATA_JSON="$(mktemp)"
  python3 "$SCRIPT_DIR/probe_nvidia_metadata.py" > "$METADATA_JSON"
}

load_metadata() {
  local kind a b c d e f g
  while IFS=$'\t' read -r kind a b c d e f g; do
    case "$kind" in
      system)
        SYSTEM_PRETTY_NAME="$a"
        SYSTEM_ID="$b"
        SYSTEM_VERSION_ID="$c"
        SYSTEM_ARCH="$d"
        SYSTEM_CURRENT_REPO_ID="$e"
        SYSTEM_CURRENT_REPO_SUPPORTED="$f"
        SYSTEM_PREFERRED_REPO_ID="$g"
        ;;
      system_extra)
        SYSTEM_PREFERRED_REPO_SUPPORTED="$a"
        SYSTEM_SUPPORTED_REPO_IDS="$b"
        SYSTEM_SECURE_BOOT="$c"
        ;;
      gpu)
        GPU_NAME="$a"
        GPU_CURRENT_DRIVER_VERSION="$b"
        GPU_INSTALLED_BRANCH="$c"
        GPU_RECOMMENDED_BRANCH="$d"
        ;;
      driver)
        DRIVER_BRANCHES+=("$a")
        DRIVER_CANDIDATE_VERSION["$a"]="$b"
        DRIVER_RECOMMENDED["$a"]="$c"
        DRIVER_INSTALLED["$a"]="$d"
        DRIVER_BEST_CUDA["$a"]="$e"
        DRIVER_COMPATIBLE_CUDA["$a"]="$f"
        ;;
      cuda_meta)
        CUDA_LATEST_RELEASE="$a"
        ;;
      cuda)
        CUDA_FAMILIES+=("$a")
        CUDA_LABEL["$a"]="$b"
        CUDA_RELEASE["$a"]="$c"
        CUDA_MIN_DRIVER["$a"]="$d"
        CUDA_PACKAGE_NAME["$a"]="$e"
        CUDA_PACKAGE_VERSION["$a"]="$f"
        CUDA_COMPATIBLE_DRIVERS["$a"]="$g"
        ;;
      cuda_runfile)
        CUDA_RUNFILE_URL["$a"]="$b"
        CUDA_RUNFILE_FILENAME["$a"]="$c"
        CUDA_RUNFILE_MD5["$a"]="$d"
        ;;
    esac
  done < <(
    python3 - "$METADATA_JSON" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1]))

def s(value):
    if value is None:
        return ""
    if isinstance(value, bool):
        return "1" if value else "0"
    return str(value)

system = data["system"]
print("\t".join([
    "system",
    s(system.get("pretty_name")),
    s(system.get("id")),
    s(system.get("version_id")),
    s(system.get("arch")),
    s(system.get("current_repo_id")),
    s(system.get("current_repo_supported")),
    s(system.get("preferred_repo_id")),
]))
print("\t".join([
    "system_extra",
    s(system.get("preferred_repo_supported")),
    ",".join(system.get("supported_repo_ids") or []),
    "unknown" if system.get("secure_boot_enabled") is None else ("1" if system.get("secure_boot_enabled") else "0"),
]))
gpu = data["gpu"]
print("\t".join([
    "gpu",
    s(gpu.get("name")),
    s(gpu.get("current_driver_version")),
    s(gpu.get("installed_branch")),
    s(gpu.get("recommended_branch")),
]))
for entry in gpu.get("open_drivers", []):
    compat = data["compatibility"]["by_driver"].get(entry["branch"], {})
    print("\t".join([
        "driver",
        s(entry.get("branch")),
        s(entry.get("candidate_version")),
        s(entry.get("recommended")),
        s(entry.get("installed")),
        s(compat.get("best_cuda")),
        ",".join(compat.get("compatible_families") or []),
    ]))
print("\t".join(["cuda_meta", s(data["cuda"].get("latest_release"))]))
for entry in data["cuda"].get("versions", []):
    compat = data["compatibility"]["by_cuda"].get(entry["family"], {})
    print("\t".join([
        "cuda",
        s(entry.get("family")),
        s(entry.get("label")),
        s(entry.get("release")),
        s(entry.get("min_driver")),
        s(entry.get("package_name")),
        s(entry.get("package_version")),
        ",".join(compat.get("compatible_branches") or []),
    ]))
    print("\t".join([
        "cuda_runfile",
        s(entry.get("family")),
        s(entry.get("runfile_url")),
        s(entry.get("runfile_filename")),
        s(entry.get("runfile_md5")),
    ]))
PY
  )
}

highest_cuda_family() {
  local family best=""
  for family in "${CUDA_FAMILIES[@]}"; do
    if [[ -z "$best" || "$(printf '%s\n%s\n' "$best" "$family" | sort -V | tail -n1)" == "$family" ]]; then
      best="$family"
    fi
  done
  printf '%s\n' "$best"
}

current_driver_supports_cuda() {
  local family
  family="$1"
  [[ -n "${GPU_CURRENT_DRIVER_VERSION:-}" ]] || return 1
  [[ "$(printf '%s\n%s\n' "${CUDA_MIN_DRIVER[$family]}" "${GPU_CURRENT_DRIVER_VERSION}" | sort -V | head -n1)" == "${CUDA_MIN_DRIVER[$family]}" ]]
}

detect_existing_nvidia_state() {
  local path unit

  APT_NVIDIA_PACKAGES=()
  HELD_NVIDIA_PACKAGES=()
  RUNFILE_DRIVER_MARKERS=()
  GRAPHICAL_SESSION_ACTIVE=0
  DISPLAY_MANAGER_ACTIVE=0
  DISPLAY_MANAGER_UNIT=""
  LOADED_NVIDIA_MODULES=""

  if [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]]; then
    GRAPHICAL_SESSION_ACTIVE=1
  fi
  case "${XDG_SESSION_TYPE:-}" in
    x11|wayland)
      GRAPHICAL_SESSION_ACTIVE=1
      ;;
  esac

  if command_exists dpkg-query; then
    mapfile -t APT_NVIDIA_PACKAGES < <(
      dpkg-query -W -f='${binary:Package}\t${Status}\n' 2>/dev/null \
        | awk '$2=="install" && $3=="ok" && $4=="installed" {print $1}' \
        | grep -E "$NVIDIA_PACKAGE_REGEX" \
        | sort -u || true
    )
  fi

  if command_exists apt-mark; then
    mapfile -t HELD_NVIDIA_PACKAGES < <(
      comm -12 \
        <(printf '%s\n' "${APT_NVIDIA_PACKAGES[@]}" | sort -u) \
        <(apt-mark showhold 2>/dev/null | grep -E "$NVIDIA_PACKAGE_REGEX" | sort -u) || true
    )
  fi

  for path in \
    /usr/bin/nvidia-uninstall \
    /usr/bin/nvidia-installer \
    /var/log/nvidia-installer.log \
    /etc/modprobe.d/nvidia-installer-disable-nouveau.conf \
    /usr/lib/modprobe.d/nvidia-installer-disable-nouveau.conf; do
    [[ -e "$path" ]] && RUNFILE_DRIVER_MARKERS+=("$path")
  done

  if command_exists systemctl; then
    for unit in display-manager gdm gdm3 sddm lightdm lxdm xdm; do
      if systemctl is-active --quiet "$unit" 2>/dev/null; then
        DISPLAY_MANAGER_ACTIVE=1
        DISPLAY_MANAGER_UNIT="$unit"
        break
      fi
    done
  fi

  if command_exists lsmod; then
    LOADED_NVIDIA_MODULES="$(
      lsmod \
        | awk '$1 ~ /^nvidia/ {print $1}' \
        | paste -sd, -
    )"
  fi
}

print_existing_state_summary() {
  printf '\nEnvironment risks:\n'
  printf '  - graphical_session=%s\n' "$( [[ "$GRAPHICAL_SESSION_ACTIVE" -eq 1 ]] && printf yes || printf no )"
  printf '  - display_manager_active=%s\n' "$( [[ "$DISPLAY_MANAGER_ACTIVE" -eq 1 ]] && printf "${DISPLAY_MANAGER_UNIT}" || printf no )"
  printf '  - loaded_nvidia_modules=%s\n' "${LOADED_NVIDIA_MODULES:-none}"
  printf '  - apt_managed_nvidia_packages=%d (%s)\n' "${#APT_NVIDIA_PACKAGES[@]}" "$(summarize_items 8 "${APT_NVIDIA_PACKAGES[@]}")"
  printf '  - held_nvidia_packages=%d (%s)\n' "${#HELD_NVIDIA_PACKAGES[@]}" "$(summarize_items 8 "${HELD_NVIDIA_PACKAGES[@]}")"
  printf '  - runfile_driver_markers=%d (%s)\n' "${#RUNFILE_DRIVER_MARKERS[@]}" "$(summarize_items 4 "${RUNFILE_DRIVER_MARKERS[@]}")"
}

driver_branch_package_regex() {
  local branch
  branch="$1"
  printf '(^nvidia-.*-%s(-open)?($|-))|(^libnvidia-.*-%s($|-))|(^linux-(modules|objects)-nvidia-%s(-open)?($|-))|(^xserver-xorg-video-nvidia-%s($|-))|(^cuda-drivers-%s(-open)?($|-))|(^nvidia-fabricmanager-%s($|-))\n' \
    "$branch" "$branch" "$branch" "$branch" "$branch" "$branch"
}

collect_installed_packages_for_branch() {
  local branch regex
  branch="$1"
  regex="$(driver_branch_package_regex "$branch")"
  [[ "${#APT_NVIDIA_PACKAGES[@]}" -gt 0 ]] || return 0
  printf '%s\n' "${APT_NVIDIA_PACKAGES[@]}" | grep -E "$regex" | sort -u || true
}

unhold_installed_nvidia_packages() {
  [[ "${#HELD_NVIDIA_PACKAGES[@]}" -gt 0 ]] || return 0
  ensure_sudo_session
  info "Removing existing NVIDIA package holds: $(join_by ' ' "${HELD_NVIDIA_PACKAGES[@]}")"
  as_root apt-mark unhold "${HELD_NVIDIA_PACKAGES[@]}"
}

purge_apt_managed_nvidia_stack() {
  [[ "${#APT_NVIDIA_PACKAGES[@]}" -gt 0 ]] || return 0

  ensure_sudo_session

  unhold_installed_nvidia_packages || warn "Failed to unhold some installed NVIDIA packages before purge."

  if command_exists systemctl; then
    for unit in nvidia-persistenced.service nvidia-powerd.service; do
      if systemctl list-unit-files "$unit" --no-legend 2>/dev/null | grep -q "^$unit"; then
        as_root systemctl stop "$unit" || true
      fi
    done
  fi

  info "Purging package-managed NVIDIA/CUDA packages: $(join_by ' ' "${APT_NVIDIA_PACKAGES[@]}")"
  apt_noninteractive purge -y "${APT_NVIDIA_PACKAGES[@]}"
  apt_noninteractive autoremove -y --purge

  as_root bash -lc '
    shopt -s nullglob
    rm -f /etc/apt/sources.list.d/cuda-*.list
    rm -f /etc/apt/preferences.d/cuda-repository-pin-600
  '
  apt_noninteractive update || true
}

stop_display_manager_if_needed() {
  [[ "$DISPLAY_MANAGER_ACTIVE" -eq 1 ]] || return 0
  ensure_sudo_session
  info "Stopping display manager: ${DISPLAY_MANAGER_UNIT}"
  as_root systemctl stop "$DISPLAY_MANAGER_UNIT"
}

run_deb_preflight() {
  detect_existing_nvidia_state

  if [[ "${#RUNFILE_DRIVER_MARKERS[@]}" -eq 0 ]]; then
    return 0
  fi

  warn "Possible runfile-managed NVIDIA driver remnants were detected: $(summarize_items 4 "${RUNFILE_DRIVER_MARKERS[@]}")"
  if [[ "$ASSUME_YES" -eq 1 ]]; then
    die "Refusing to continue under --yes while runfile driver remnants are present."
  fi

  local continue_anyway=0
  prompt_bool_text continue_anyway "Possible runfile-managed NVIDIA driver remnants were found. Continue with apt-managed installation anyway?" 0
  [[ "$continue_anyway" -eq 1 ]] || die "Aborted to avoid mixing apt-managed drivers with possible runfile remnants."
}

run_runfile_preflight() {
  detect_existing_nvidia_state

  if [[ "$SYSTEM_SECURE_BOOT" == "1" ]]; then
    die ".run mode is blocked while Secure Boot is enabled. Disable Secure Boot or use the package-managed driver path."
  fi

  if [[ "$GRAPHICAL_SESSION_ACTIVE" -eq 1 ]]; then
    die ".run mode must be started from a text TTY, not from an active graphical session. Switch to a console and rerun."
  fi

  if [[ "${#APT_NVIDIA_PACKAGES[@]}" -gt 0 ]]; then
    warn "Package-managed NVIDIA/CUDA packages are installed (${#APT_NVIDIA_PACKAGES[@]} packages): $(summarize_items 8 "${APT_NVIDIA_PACKAGES[@]}")"
    if [[ "$ASSUME_YES" -eq 1 ]]; then
      die "Refusing to purge package-managed NVIDIA/CUDA packages under --yes. Re-run interactively."
    fi
    local purge_stack=0
    prompt_bool_text purge_stack "Purge the package-managed NVIDIA/CUDA stack before launching the runfile installer?" 0
    [[ "$purge_stack" -eq 1 ]] || die "Aborted to avoid mixing apt-managed NVIDIA/CUDA packages with the runfile installer."
    purge_apt_managed_nvidia_stack
    detect_existing_nvidia_state
  fi

  if [[ "$DISPLAY_MANAGER_ACTIVE" -eq 1 ]]; then
    if [[ "$ASSUME_YES" -eq 1 ]]; then
      die "Refusing to stop the active display manager under --yes. Re-run interactively from a TTY."
    fi
    local stop_dm=0
    prompt_bool_text stop_dm "Display manager ${DISPLAY_MANAGER_UNIT} is active. Stop it now before launching the runfile installer?" 1
    [[ "$stop_dm" -eq 1 ]] || die "Aborted because the NVIDIA runfile installer should not be started while a display manager is active."
    stop_display_manager_if_needed
    detect_existing_nvidia_state
  fi

  if [[ -n "${LOADED_NVIDIA_MODULES:-}" ]]; then
    warn "NVIDIA kernel modules are still loaded: ${LOADED_NVIDIA_MODULES}. The runfile installer may unload them or ask for a reboot."
  fi
}

resolve_default_driver_branch() {
  local fallback
  if [[ -n "${GPU_INSTALLED_BRANCH:-}" ]]; then
    printf '%s\n' "$GPU_INSTALLED_BRANCH"
    return 0
  fi
  if [[ -n "${GPU_RECOMMENDED_BRANCH:-}" ]]; then
    printf '%s\n' "$GPU_RECOMMENDED_BRANCH"
    return 0
  fi
  fallback="${DRIVER_BRANCHES[${#DRIVER_BRANCHES[@]}-1]:-}"
  printf '%s\n' "$fallback"
}

collect_install_method() {
  local default_method
  default_method="deb"
  if [[ "$ASSUME_YES" -eq 1 ]]; then
    INSTALL_METHOD="$default_method"
    return 0
  fi
  choose_one INSTALL_METHOD \
    "NVIDIA Setup" \
    "Choose the installation path." \
    "$default_method" \
    "deb|package-managed (APT/open driver)|Install an APT-managed open driver branch and optionally an APT-packaged toolkit" \
    "run|NVIDIA runfile installer|Choose a CUDA version, then hand control to NVIDIA's own driver + toolkit installer" \
    "manual|preview only|Resolve the open-driver packages and runfile links without changing the system"
}

collect_cuda_choice() {
  local default_choice latest_family family prompt_text latest_desc option_desc
  local -a options=()
  latest_family="$(highest_cuda_family)"
  default_choice="latest"
  case "$INSTALL_METHOD" in
    run)
      prompt_text="Choose the CUDA runfile version to launch."
      latest_desc="Launch the highest discovered CUDA runfile version"
      ;;
    manual)
      prompt_text="Choose which CUDA version to resolve in the preview. 'latest' is resolved after the driver branch is known."
      latest_desc="Resolve to the highest compatible CUDA after the driver branch is known"
      ;;
    *)
      prompt_text="Choose a CUDA target. 'latest' is resolved after the driver branch is known."
      latest_desc="Resolve to the highest compatible CUDA after the driver branch is known"
      ;;
  esac
  options+=("latest|latest (${latest_family})|${latest_desc}")
  for family in "${CUDA_FAMILIES[@]}"; do
    case "$INSTALL_METHOD" in
      run)
        option_desc="Launch the NVIDIA runfile installer for CUDA ${family}"
        ;;
      manual)
        option_desc="Resolve this exact CUDA version in the preview"
        ;;
      *)
        option_desc="Compatible branches: ${CUDA_COMPATIBLE_DRIVERS[$family]}"
        ;;
    esac
    options+=("${family}|$(cuda_display_label "$family")|${option_desc}")
  done
  if [[ "$INSTALL_METHOD" != "run" ]]; then
    options+=("decide_later|decide later|Driver first, postpone toolkit installation")
  fi
  if [[ "$ASSUME_YES" -eq 1 ]]; then
    CUDA_CHOICE="$default_choice"
    return 0
  fi
  choose_one CUDA_CHOICE \
    "CUDA Version" \
    "$prompt_text" \
    "$default_choice" \
    "${options[@]}"
}

compatible_driver_options_for_cuda() {
  local family branch
  family="$1"
  if [[ "$family" == "latest" || "$family" == "decide_later" ]]; then
    printf '%s\n' "${DRIVER_BRANCHES[@]}"
    return 0
  fi
  for branch in "${DRIVER_BRANCHES[@]}"; do
    if [[ ",${CUDA_COMPATIBLE_DRIVERS[$family]}," == *",${branch},"* ]]; then
      printf '%s\n' "$branch"
    fi
  done
}

collect_driver_branch_for_deb() {
  local default_branch latest_branch branch driver_choice
  local -a compatible_branches=()
  local -a options=()

  while IFS= read -r branch; do
    [[ -n "$branch" ]] || continue
    compatible_branches+=("$branch")
  done < <(compatible_driver_options_for_cuda "$CUDA_CHOICE")

  [[ "${#compatible_branches[@]}" -gt 0 ]] || die "No open driver branch is compatible with CUDA choice '${CUDA_CHOICE}'."
  latest_branch="${compatible_branches[${#compatible_branches[@]}-1]}"

  default_branch="$(resolve_default_driver_branch)"
  if [[ -z "$default_branch" || ",$(join_by , "${compatible_branches[@]}")," != *",${default_branch},"* ]]; then
    default_branch="$latest_branch"
  fi

  options+=("latest|latest (${latest_branch}-open)|Install the highest compatible open driver branch without locking it")
  for branch in "${compatible_branches[@]}"; do
    options+=("${branch}|$(branch_display_label "$branch")|Candidate ${DRIVER_CANDIDATE_VERSION[$branch]}")
  done

  if [[ "$ASSUME_YES" -eq 1 ]]; then
    DRIVER_BRANCH="$default_branch"
    DRIVER_SELECTION_MODE="branch"
    return 0
  fi

  choose_one driver_choice \
    "Open Driver Branch" \
    "Choose the package-managed open driver branch." \
    "$default_branch" \
    "${options[@]}"

  if [[ "$driver_choice" == "latest" ]]; then
    DRIVER_SELECTION_MODE="latest"
    DRIVER_BRANCH="$latest_branch"
  else
    DRIVER_SELECTION_MODE="branch"
    DRIVER_BRANCH="$driver_choice"
  fi
}

resolve_cuda_for_deb() {
  case "$CUDA_CHOICE" in
    latest)
      RESOLVED_CUDA_FAMILY="${DRIVER_BEST_CUDA[$DRIVER_BRANCH]:-}"
      [[ -n "$RESOLVED_CUDA_FAMILY" ]] || die "Driver branch ${DRIVER_BRANCH} does not satisfy any probed CUDA toolkit version."
      ;;
    decide_later)
      RESOLVED_CUDA_FAMILY=""
      ;;
    *)
      RESOLVED_CUDA_FAMILY="$CUDA_CHOICE"
      ;;
  esac
}

collect_driver_lock_preference() {
  local default_lock=1
  if [[ "$DRIVER_SELECTION_MODE" == "latest" ]]; then
    LOCK_DRIVER_BRANCH=0
    return 0
  fi
  if [[ "$ASSUME_YES" -eq 1 ]]; then
    LOCK_DRIVER_BRANCH=0
    return 0
  fi
  prompt_bool_text LOCK_DRIVER_BRANCH "Pin NVIDIA driver branch ${DRIVER_BRANCH}-open after installation?" "$default_lock"
}

collect_toolkit_flag_for_deb() {
  local default_flag=1
  if [[ "$CUDA_CHOICE" == "decide_later" ]]; then
    default_flag=0
  fi
  if [[ "$ASSUME_YES" -eq 1 ]]; then
    INSTALL_TOOLKIT="$default_flag"
    return 0
  fi
  prompt_bool_text INSTALL_TOOLKIT "Install the CUDA toolkit now?" "$default_flag"
}

collect_toolkit_version_after_decide_later() {
  local branch family default_family
  local -a options=()

  default_family="${DRIVER_BEST_CUDA[$DRIVER_BRANCH]:-}"
  [[ -n "$default_family" ]] || die "Driver branch ${DRIVER_BRANCH} has no compatible CUDA toolkit in the probed metadata."

  options+=("latest|latest (${default_family})|Resolve to the highest CUDA supported by driver ${DRIVER_BRANCH}-open")
  IFS=',' read -r -a branch_families <<< "${DRIVER_COMPATIBLE_CUDA[$DRIVER_BRANCH]}"
  for family in "${branch_families[@]}"; do
    [[ -n "$family" ]] || continue
    options+=("${family}|$(cuda_display_label "$family")|Explicit toolkit selection")
  done

  choose_one CUDA_CHOICE \
    "CUDA Toolkit" \
    "Choose the toolkit version to install now." \
    "latest" \
    "${options[@]}"

  if [[ "$CUDA_CHOICE" == "latest" ]]; then
    RESOLVED_CUDA_FAMILY="$default_family"
  else
    RESOLVED_CUDA_FAMILY="$CUDA_CHOICE"
  fi
}

maybe_collect_unsupported_repo_override() {
  local default_flag=1
  [[ -n "$RESOLVED_CUDA_FAMILY" ]] || return 0
  if [[ "$SYSTEM_CURRENT_REPO_SUPPORTED" == "1" ]]; then
    ALLOW_UNSUPPORTED_CUDA_REPO=1
    return 0
  fi
  if [[ -z "$SYSTEM_PREFERRED_REPO_ID" ]]; then
    die "No supported NVIDIA CUDA apt repo was discovered for distro '${SYSTEM_PRETTY_NAME}'."
  fi
  if [[ "$ASSUME_YES" -eq 1 ]]; then
    ALLOW_UNSUPPORTED_CUDA_REPO=0
    INSTALL_TOOLKIT=0
    RESOLVED_CUDA_FAMILY=""
    warn "Current distro repo is unsupported. Skipping toolkit installation under --yes instead of auto-enabling a repo override."
    return 0
  fi
  prompt_bool_text ALLOW_UNSUPPORTED_CUDA_REPO "This distro has no official CUDA APT repo. Allow a toolkit repo override via ${SYSTEM_PREFERRED_REPO_ID}?" "$default_flag"
  if [[ "$ALLOW_UNSUPPORTED_CUDA_REPO" -ne 1 ]]; then
    INSTALL_TOOLKIT=0
    RESOLVED_CUDA_FAMILY=""
    warn "Skipping toolkit installation because the NVIDIA apt repo override was declined."
  fi
}

resolve_run_toolkit() {
  case "$CUDA_CHOICE" in
    latest)
      RESOLVED_CUDA_FAMILY="$(highest_cuda_family)"
      ;;
    decide_later)
      RESOLVED_CUDA_FAMILY=""
      ;;
    *)
      RESOLVED_CUDA_FAMILY="$CUDA_CHOICE"
      ;;
  esac
}

collect_run_driver_strategy() {
  [[ -n "$RESOLVED_CUDA_FAMILY" ]] || return 0
  has_interactive_tty || die ".run mode requires an interactive terminal because the NVIDIA installer uses its own UI."
  warn ".run mode will download the CUDA ${RESOLVED_CUDA_FAMILY} runfile and then hand control to NVIDIA's official installer. Its default path may replace the current package-managed open driver with a proprietary driver."
  if current_driver_supports_cuda "$RESOLVED_CUDA_FAMILY"; then
    info "Current driver ${GPU_CURRENT_DRIVER_VERSION} already satisfies CUDA ${RESOLVED_CUDA_FAMILY}, but the runfile installer will still decide how to handle the driver."
  else
    warn "Current driver ${GPU_CURRENT_DRIVER_VERSION:-unknown} does not satisfy CUDA ${RESOLVED_CUDA_FAMILY}. The runfile installer is expected to handle the driver path itself."
  fi
}

print_probe_summary() {
  local branch family example_branch example_family
  cat <<EOF
NVIDIA probe summary:
  - system=${SYSTEM_PRETTY_NAME}
  - arch=${SYSTEM_ARCH}
  - gpu=${GPU_NAME:-unknown}
  - current_driver=${GPU_CURRENT_DRIVER_VERSION:-none}
  - installed_open_branch=${GPU_INSTALLED_BRANCH:-none}
  - recommended_open_branch=${GPU_RECOMMENDED_BRANCH:-none}
  - current_cuda_repo=${SYSTEM_CURRENT_REPO_ID:-none}
  - current_cuda_repo_supported=$( [[ "$SYSTEM_CURRENT_REPO_SUPPORTED" == "1" ]] && printf yes || printf no )
  - preferred_cuda_repo=${SYSTEM_PREFERRED_REPO_ID:-none}
  - secure_boot=$( [[ "$SYSTEM_SECURE_BOOT" == "1" ]] && printf enabled || [[ "$SYSTEM_SECURE_BOOT" == "0" ]] && printf disabled || printf unknown )
  - latest_cuda_release=${CUDA_LATEST_RELEASE:-unknown}
EOF
  printf '\nOpen driver branches:\n'
  for branch in "${DRIVER_BRANCHES[@]}"; do
    printf '  - %s: candidate=%s, installed=%s, recommended=%s, best_cuda=%s\n' \
      "$branch" \
      "${DRIVER_CANDIDATE_VERSION[$branch]}" \
      "$( [[ "${DRIVER_INSTALLED[$branch]}" == "1" ]] && printf yes || printf no )" \
      "$( [[ "${DRIVER_RECOMMENDED[$branch]}" == "1" ]] && printf yes || printf no )" \
      "${DRIVER_BEST_CUDA[$branch]:-n/a}"
  done
  printf '\nCUDA versions:\n'
  for family in "${CUDA_FAMILIES[@]}"; do
    printf '  - %s: release=%s, min_driver=%s, deb=%s (%s), compatible_branches=%s\n' \
      "$family" \
      "${CUDA_RELEASE[$family]}" \
      "${CUDA_MIN_DRIVER[$family]}" \
      "${CUDA_PACKAGE_NAME[$family]}" \
      "${CUDA_PACKAGE_VERSION[$family]}" \
      "${CUDA_COMPATIBLE_DRIVERS[$family]}"
    printf '      runfile=%s\n' "${CUDA_RUNFILE_FILENAME[$family]}"
  done
  example_branch="${GPU_INSTALLED_BRANCH:-${GPU_RECOMMENDED_BRANCH:-${DRIVER_BRANCHES[0]:-}}}"
  example_family="${CUDA_FAMILIES[0]:-}"
  if [[ -n "$example_branch" || -n "$example_family" ]]; then
    printf '\nExamples:\n'
    if [[ -n "$example_branch" ]]; then
      printf '  - driver %s -> best CUDA %s\n' "$example_branch" "${DRIVER_BEST_CUDA[$example_branch]:-n/a}"
    fi
    if [[ -n "$example_family" ]]; then
      printf '  - CUDA %s -> compatible drivers %s\n' "$example_family" "${CUDA_COMPATIBLE_DRIVERS[$example_family]:-n/a}"
    fi
  fi
  print_existing_state_summary
}

print_selection_summary() {
  cat <<EOF
Resolved plan:
  - method=$(install_method_label "$INSTALL_METHOD")
  - cuda_choice=${CUDA_CHOICE}
  - resolved_cuda=${RESOLVED_CUDA_FAMILY:-none}
EOF
  case "$INSTALL_METHOD" in
    deb)
      cat <<EOF
  - deb_driver_branch=${DRIVER_BRANCH:-none}
  - driver_selection_mode=${DRIVER_SELECTION_MODE:-n/a}
  - lock_driver_branch=$(bool_word "$LOCK_DRIVER_BRANCH")
  - install_toolkit=$(bool_word "$INSTALL_TOOLKIT")
  - allow_unsupported_cuda_repo_override=$(bool_word "$ALLOW_UNSUPPORTED_CUDA_REPO")
EOF
      ;;
    run)
      cat <<'EOF'
  - runfile_mode=official-default-installer
EOF
      ;;
    manual)
      cat <<EOF
  - deb_driver_branch=${DRIVER_BRANCH:-none}
  - driver_selection_mode=${DRIVER_SELECTION_MODE:-n/a}
  - lock_driver_branch=$(bool_word "$LOCK_DRIVER_BRANCH")
  - preview_only=yes
EOF
      ;;
  esac
}

ensure_driver_prereqs() {
  local -a packages=(build-essential dkms curl ca-certificates)
  local headers_pkg
  headers_pkg="linux-headers-$(uname -r)"

  apt_noninteractive update
  if package_available "$headers_pkg"; then
    apt_noninteractive install -y "$headers_pkg" "${packages[@]}"
  else
    warn "Kernel headers package not available right now: ${headers_pkg}. Continuing without it."
    apt_noninteractive install -y "${packages[@]}"
  fi
}

install_open_driver_branch() {
  local branch package
  branch="$1"
  package="nvidia-driver-${branch}-open"

  ensure_sudo_session
  detect_existing_nvidia_state
  unhold_installed_nvidia_packages || warn "Failed to remove some existing NVIDIA package holds before install."
  preseed_grub_if_possible
  ensure_driver_prereqs
  apt_noninteractive install -y "$package"
  rebuild_initramfs_if_possible || true
  rebuild_grub_if_possible || true
  info "Installed open driver package ${package}."
}

hold_driver_branch_packages() {
  local branch
  local -a branch_packages=()
  branch="$1"

  detect_existing_nvidia_state
  mapfile -t branch_packages < <(collect_installed_packages_for_branch "$branch")
  if [[ "${#branch_packages[@]}" -eq 0 ]]; then
    warn "No installed packages were detected for NVIDIA driver branch ${branch}; skipping hold."
    return 0
  fi

  ensure_sudo_session
  info "Locking NVIDIA driver branch ${branch}: $(join_by ' ' "${branch_packages[@]}")"
  as_root apt-mark hold "${branch_packages[@]}"
}

configure_cuda_repo() {
  local repo_id keyring_url keyring_path
  repo_id="$1"
  keyring_url="https://developer.download.nvidia.com/compute/cuda/repos/${repo_id}/x86_64/cuda-keyring_1.1-1_all.deb"
  keyring_path="/tmp/cuda-keyring-${repo_id}.deb"

  ensure_sudo_session
  ensure_command curl
  info "Configuring NVIDIA CUDA apt repo: ${repo_id}"
  download_url_with_speed_guard "$keyring_url" "$keyring_path"
  as_root dpkg -i "$keyring_path"
  as_root bash -lc '
    shopt -s nullglob
    desired="cuda-'"${repo_id}"'-x86_64.list"
    for file in /etc/apt/sources.list.d/cuda-*.list; do
      if [[ "$(basename "$file")" != "$desired" ]]; then
        rm -f -- "$file"
      fi
    done
  '
  apt_noninteractive update
}

install_cuda_toolkit_deb() {
  local family package_name
  family="$1"
  package_name="${CUDA_PACKAGE_NAME[$family]}"
  [[ -n "$package_name" ]] || die "No deb toolkit package metadata found for CUDA ${family}."
  ensure_sudo_session
  apt_noninteractive install -y "$package_name"
  info "Installed CUDA toolkit package ${package_name} (${CUDA_PACKAGE_VERSION[$family]})."
}

download_with_md5() {
  local url target_path expected_md5 actual_md5
  url="$1"
  target_path="$2"
  expected_md5="$3"

  download_url_with_speed_guard "$url" "$target_path"
  if [[ -n "$expected_md5" ]]; then
    actual_md5="$(md5sum "$target_path" | awk '{print $1}')"
    if [[ "$actual_md5" != "$expected_md5" ]]; then
      die "MD5 mismatch for ${target_path}: expected ${expected_md5}, got ${actual_md5}"
    fi
  fi
}

install_cuda_toolkit_runfile() {
  local family runfile_url runfile_name runfile_md5 cache_dir runfile_path
  family="$1"
  runfile_url="${CUDA_RUNFILE_URL[$family]}"
  runfile_name="${CUDA_RUNFILE_FILENAME[$family]}"
  runfile_md5="${CUDA_RUNFILE_MD5[$family]}"

  [[ -n "$runfile_url" && -n "$runfile_name" ]] || die "No runfile metadata found for CUDA ${family}."

  cache_dir="$HOME/.cache/linux-setup/nvidia"
  mkdir -p "$cache_dir"
  runfile_path="$cache_dir/$runfile_name"

  download_with_md5 "$runfile_url" "$runfile_path" "$runfile_md5"
  ensure_sudo_session
  has_interactive_tty || die ".run mode requires an interactive terminal because the NVIDIA installer uses its own UI."
  info "Launching the official NVIDIA runfile installer: ${runfile_name}"
  info "Use the default selections there if you want the standard NVIDIA driver + CUDA install path."
  as_root sh "$runfile_path"
  info "The NVIDIA runfile installer exited successfully."
}

print_manual_plan() {
  local family runfile_url package_name
  printf 'Preview plan:\n'
  printf '  - preview_only=yes\n'
  if [[ -n "$DRIVER_BRANCH" ]]; then
    printf '  - deb/open-driver package: nvidia-driver-%s-open\n' "$DRIVER_BRANCH"
    printf '  - lock selected driver branch: %s\n' "$(bool_word "$LOCK_DRIVER_BRANCH")"
  fi
  if [[ -n "$RESOLVED_CUDA_FAMILY" ]]; then
    family="$RESOLVED_CUDA_FAMILY"
    package_name="${CUDA_PACKAGE_NAME[$family]:-}"
    runfile_url="${CUDA_RUNFILE_URL[$family]:-}"
    printf '  - CUDA family: %s (%s)\n' "$family" "${CUDA_LABEL[$family]}"
    if [[ -n "$package_name" ]]; then
      printf '  - deb toolkit package: %s (%s)\n' "$package_name" "${CUDA_PACKAGE_VERSION[$family]}"
    fi
    if [[ "$SYSTEM_CURRENT_REPO_SUPPORTED" != "1" && -n "$SYSTEM_PREFERRED_REPO_ID" ]]; then
      printf '  - deb repo override would be required on this system: %s\n' "$SYSTEM_PREFERRED_REPO_ID"
    fi
    if [[ -n "$runfile_url" ]]; then
      printf '  - runfile: %s\n' "$runfile_url"
    fi
  else
    printf '  - toolkit: decide later\n'
  fi
}

run_apply_plan() {
  case "$INSTALL_METHOD" in
    deb)
      install_open_driver_branch "$DRIVER_BRANCH"
      if [[ "$LOCK_DRIVER_BRANCH" -eq 1 ]]; then
        hold_driver_branch_packages "$DRIVER_BRANCH"
      fi
      if [[ "$INSTALL_TOOLKIT" -eq 1 && -n "$RESOLVED_CUDA_FAMILY" ]]; then
        if [[ "$ALLOW_UNSUPPORTED_CUDA_REPO" -eq 1 && -n "$SYSTEM_PREFERRED_REPO_ID" ]]; then
          configure_cuda_repo "$SYSTEM_PREFERRED_REPO_ID"
        fi
        install_cuda_toolkit_deb "$RESOLVED_CUDA_FAMILY"
      fi
      ;;
    run)
      if [[ -n "$RESOLVED_CUDA_FAMILY" ]]; then
        install_cuda_toolkit_runfile "$RESOLVED_CUDA_FAMILY"
      else
        info "No CUDA toolkit was chosen. Nothing else to install in runfile mode."
      fi
      ;;
    manual)
      print_manual_plan
      ;;
    *)
      die "Unsupported install method: ${INSTALL_METHOD}"
      ;;
  esac
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --check)
        RUN_MODE="check"
        ;;
      --apply)
        RUN_MODE="apply"
        ;;
      --yes)
        ASSUME_YES=1
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
}

main() {
  parse_args "$@"
  probe_metadata
  load_metadata
  detect_existing_nvidia_state

  if [[ "${#DRIVER_BRANCHES[@]}" -eq 0 ]]; then
    die "No open NVIDIA driver branches were detected from the current apt sources."
  fi
  if [[ "${#CUDA_FAMILIES[@]}" -eq 0 ]]; then
    die "No CUDA toolkit versions were discovered from the probed NVIDIA metadata."
  fi

  if [[ "$RUN_MODE" == "check" ]]; then
    print_probe_summary
    exit 0
  fi

  collect_install_method
  collect_cuda_choice

  case "$INSTALL_METHOD" in
    deb)
      run_deb_preflight
      collect_driver_branch_for_deb
      resolve_cuda_for_deb
      collect_driver_lock_preference
      collect_toolkit_flag_for_deb
      if [[ "$INSTALL_TOOLKIT" -eq 1 && "$CUDA_CHOICE" == "decide_later" ]]; then
        collect_toolkit_version_after_decide_later
      fi
      maybe_collect_unsupported_repo_override
      ;;
    run)
      resolve_run_toolkit
      DRIVER_SELECTION_MODE="runfile"
      LOCK_DRIVER_BRANCH=0
      collect_run_driver_strategy
      run_runfile_preflight
      INSTALL_TOOLKIT=$([[ -n "$RESOLVED_CUDA_FAMILY" ]] && printf 1 || printf 0)
      ALLOW_UNSUPPORTED_CUDA_REPO=0
      ;;
    manual)
      collect_driver_branch_for_deb
      resolve_cuda_for_deb
      collect_driver_lock_preference
      INSTALL_TOOLKIT=0
      ALLOW_UNSUPPORTED_CUDA_REPO=0
      ;;
    *)
      die "Unsupported install method: ${INSTALL_METHOD}"
      ;;
  esac

  print_selection_summary
  run_apply_plan

  if [[ "$INSTALL_METHOD" != "manual" ]]; then
    cat <<'EOF'
Post-install checks to run after the next reboot if the driver changed:
  - nvidia-smi
  - nvcc --version
  - modinfo nvidia | head
EOF
  fi
}

main "$@"
