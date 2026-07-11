#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
source "$ROOT_DIR/lib/common.sh"
source "$ROOT_DIR/lib/apt-mirror.sh"

MODE="auto"
APT_ETC_DIR="${LINUX_SETUP_APT_ETC_DIR:-/etc/apt}"
OS_RELEASE_FILE="${LINUX_SETUP_OS_RELEASE_FILE:-/etc/os-release}"

usage() {
  cat <<'EOF'
Select and apply a stable APT mirror strategy.

Usage:
  manage.sh maintain mirror [--check] [--apply] [--auto] [--list] [--reset]

Options:
  --check    Dry run mode (default)
  --apply    Apply the selected mirror
  --auto     Stable-first selection (implies --apply): prefer official mirror when reachable, otherwise fallback to the best reachable mirror
  --list     Probe and rank reachable mirrors
  --reset    Force restore to the official mirror (implies --apply)

Notes:
  - Supports Debian and Ubuntu (sources.list or .sources DEB822 format).
  - Uses HTTPS probing and writes HTTPS mirror URLs.
  - Keeps Ubuntu/Debian official security hosts unchanged.
  - Backups are created in /etc/apt/ before modifying.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)
      APPLY=0
      ;;
    --apply)
      APPLY=1
      ;;
    --auto)
      APPLY=1
      MODE="auto"
      ;;
    --list)
      MODE="list"
      ;;
    --reset)
      APPLY=1
      MODE="reset"
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

ensure_command curl
ensure_command sed
ensure_command awk
ensure_command python3

OS_ID="$(awk -F= '/^ID=/{print $2}' "$OS_RELEASE_FILE" | tr -d '"')"
if [[ "$OS_ID" != "ubuntu" && "$OS_ID" != "debian" ]]; then
  die "Unsupported OS: $OS_ID. Only Ubuntu and Debian are supported."
fi

OS_CODENAME="$(awk -F= '/^(VERSION_CODENAME|UBUNTU_CODENAME)=/{print $2}' "$OS_RELEASE_FILE" | tr -d '"' | tail -n 1)"

declare -A MIRRORS=(
  ["official_ubuntu"]="archive.ubuntu.com"
  ["official_debian"]="deb.debian.org"
  ["tuna"]="mirrors.tuna.tsinghua.edu.cn"
  ["aliyun"]="mirrors.aliyun.com"
  ["ustc"]="mirrors.ustc.edu.cn"
)

mirror_probe_path() {
  case "$OS_ID" in
    ubuntu)
      if [[ -n "$OS_CODENAME" ]]; then
        printf '/ubuntu/dists/%s/Release\n' "$OS_CODENAME"
      else
        printf '/ubuntu/\n'
      fi
      ;;
    debian)
      if [[ -n "$OS_CODENAME" ]]; then
        printf '/debian/dists/%s/Release\n' "$OS_CODENAME"
      else
        printf '/debian/\n'
      fi
      ;;
  esac
}

TEST_PATH="$(mirror_probe_path)"

test_mirror() {
  local host url sample rtt_ms sum=0
  local attempt count=0

  host="$1"
  url="https://${host}${TEST_PATH}"

  for attempt in 1 2 3; do
    if ! sample="$(
      curl \
        -fsSIL \
        --connect-timeout 3 \
        --max-time 8 \
        -o /dev/null \
        -w "%{time_connect}" \
        "$url" 2>/dev/null
    )"; then
      printf '9999\n'
      return 0
    fi

    rtt_ms="$(awk -v rtt="$sample" 'BEGIN { printf "%.0f\n", rtt * 1000 }')"
    sum=$((sum + rtt_ms))
    count=$((count + 1))
  done

  if [[ "$count" -eq 0 ]]; then
    printf '9999\n'
    return 0
  fi

  printf '%s\n' "$((sum / count))"
}

rank_mirrors() {
  local -a results=()
  local -a mirror_keys
  local key host rtt

  mirror_keys=("official_${OS_ID}" tuna aliyun ustc)
  info "Probing mirrors over HTTPS (3 samples each)..." >&2

  for key in "${mirror_keys[@]}"; do
    host="${MIRRORS[$key]:-}"
    [[ -n "$host" ]] || continue

    rtt="$(test_mirror "$host")"
    if [[ "$rtt" != "9999" ]]; then
      results+=("${rtt}:${host}")
    fi
  done

  if [[ "${#results[@]}" -eq 0 ]]; then
    die "No reachable mirrors detected over HTTPS. Check your network connection."
  fi

  printf '%s\n' "${results[@]}" | sort -n
}

get_active_source_files() {
  local -a files=()
  if [[ -f "$APT_ETC_DIR/sources.list" ]]; then
    files+=("$APT_ETC_DIR/sources.list")
  fi
  if [[ -f "$APT_ETC_DIR/sources.list.d/${OS_ID}.sources" ]]; then
    files+=("$APT_ETC_DIR/sources.list.d/${OS_ID}.sources")
  fi
  printf '%s\n' "${files[@]}"
}

get_current_mirror() {
  local -a files
  local url

  mapfile -t files < <(get_active_source_files)
  if [[ "${#files[@]}" -eq 0 ]]; then
    printf 'unknown\n'
    return 0
  fi

  for file in "${files[@]}"; do
    url="$(grep -vE '^[[:space:]]*(#|$)' "$file" \
      | grep -Eo '(URIs:|deb)[[:space:]]+https?://[^/[:space:]]+' \
      | sed -E 's/^(URIs:|deb)[[:space:]]+//' \
      | head -n 1 || true)"
    if [[ -n "$url" ]]; then
      url="${url#http://}"
      url="${url#https://}"
      printf '%s\n' "$url"
      return 0
    fi
  done

  printf 'unknown\n'
}

MIRROR_WORKDIR=""
declare -a MIRROR_SOURCE_FILES=()
declare -a MIRROR_BACKUP_FILES=()
declare -a MIRROR_CANDIDATE_FILES=()

cleanup_mirror_workdir() {
  if [[ -n "$MIRROR_WORKDIR" && -d "$MIRROR_WORKDIR" ]]; then
    rm -rf "$MIRROR_WORKDIR"
  fi
}

prepare_mirror_candidates() {
  local target_host file backup_file candidate_file index=0

  target_host="$1"
  mapfile -t MIRROR_SOURCE_FILES < <(get_active_source_files)
  [[ ${#MIRROR_SOURCE_FILES[@]} -gt 0 ]] || die "No active APT source files were found."

  MIRROR_WORKDIR="$(mktemp -d /tmp/linux-setup-apt-mirror.XXXXXX)"
  trap cleanup_mirror_workdir EXIT
  MIRROR_BACKUP_FILES=()
  MIRROR_CANDIDATE_FILES=()

  for file in "${MIRROR_SOURCE_FILES[@]}"; do
    backup_file="${file}.linux-setup.bak"
    if [[ ! -f "$backup_file" ]]; then
      info "Creating backup: $backup_file"
      run_as_root cp -a -- "$file" "$backup_file"
    fi

    backup_file="$MIRROR_WORKDIR/$index.original"
    candidate_file="$MIRROR_WORKDIR/$index.candidate"
    as_root cp -a -- "$file" "$backup_file"
    as_root cp -a -- "$file" "$candidate_file"
    render_apt_mirror_candidate "$file" "$candidate_file" "$OS_ID" "$target_host"
    MIRROR_BACKUP_FILES+=("$backup_file")
    MIRROR_CANDIDATE_FILES+=("$candidate_file")
    index=$((index + 1))
  done
}

apply_mirror_candidates() {
  local index

  for index in "${!MIRROR_SOURCE_FILES[@]}"; do
    info "Applying selected mirror to ${MIRROR_SOURCE_FILES[$index]} (HTTPS)"
    run_as_root cp -a -- "${MIRROR_CANDIDATE_FILES[$index]}" "${MIRROR_SOURCE_FILES[$index]}" || return 1
  done
}

restore_mirror_sources() {
  local index failed=0

  warn "Restoring APT source files from the pre-change copies."
  for index in "${!MIRROR_SOURCE_FILES[@]}"; do
    if ! run_as_root cp -a -- "${MIRROR_BACKUP_FILES[$index]}" "${MIRROR_SOURCE_FILES[$index]}"; then
      failed=1
    fi
  done

  return "$failed"
}

current_host="$(get_current_mirror)"
official_host="${MIRRORS[official_${OS_ID}]}"

if [[ "$MODE" == "list" ]]; then
  info "Current active mirror: $current_host"
  ranked="$(rank_mirrors)"
  printf '\nLatency (ms) | Mirror\n'
  printf -- '-----------------------------------\n'
  for item in $ranked; do
    ms="${item%%:*}"
    host="${item##*:}"
    printf '%-12s | %s\n' "${ms}ms" "$host"
  done
  exit 0
fi

if [[ "$MODE" == "reset" ]]; then
  target_host="$official_host"
else
  info "Current active mirror: $current_host"
  ranked="$(rank_mirrors)"
  official_item="$(printf '%s\n' "$ranked" | awk -F: -v host="$official_host" '$2 == host {print; exit}')"
  if [[ -n "$official_item" ]]; then
    target_host="$official_host"
    official_ms="${official_item%%:*}"
    info "Stable-first policy: official mirror is reachable, selecting ${target_host} (${official_ms}ms)."
  else
    best_item="$(printf '%s\n' "$ranked" | head -n 1)"
    target_host="${best_item##*:}"
    best_ms="${best_item%%:*}"
    warn "Official mirror is not reachable now; falling back to ${target_host} (${best_ms}ms)."
  fi
fi

if [[ "$current_host" == "$target_host" ]]; then
  info "System is already using target mirror: $target_host. Nothing to do."
  exit 0
fi

if [[ "$APPLY" -ne 1 ]]; then
  cat <<EOF

This was a check run. The script would:
  1. Backup:
$(get_active_source_files | sed 's/^/     - /')
  2. Replace '${OS_ID}' repository URLs with: https://${target_host}/${OS_ID}/
  3. Keep official security hosts unchanged when present.

Run with --apply to execute.
EOF
  exit 0
fi

ensure_sudo_session
prepare_mirror_candidates "$target_host"
if ! apply_mirror_candidates; then
  if restore_mirror_sources; then
    die "Failed to replace the APT mirror; original source files were restored."
  fi
  die "Failed to replace the APT mirror and failed to restore the original source files."
fi

info "Updating APT cache..."
if ! run_as_root apt-get update -y; then
  if ! restore_mirror_sources; then
    die "APT metadata refresh failed and the original source files could not be restored."
  fi
  info "Refreshing APT cache from the restored source files..."
  if ! run_as_root apt-get update -y; then
    die "APT metadata refresh failed; original source files were restored, but their metadata refresh also failed."
  fi
  die "APT metadata refresh failed; original source files were restored and their metadata was refreshed."
fi

info "Successfully switched APT mirror to $target_host."
