#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
source "$ROOT_DIR/lib/common.sh"

ASSUME_YES=0
RUN_MODE="check"
PLAN_FILE=""
RESULT_LOG=""
RUN_LOG=""
SUMMARY_FILE=""
TIMESTAMP=""
PROFILE_EXPLICIT=0

INSTALL_PROFILE="desktop"
INSTALL_SHELL_ENV=1
INSTALL_DESKTOP_ESSENTIALS=1
INSTALL_CHINESE_SUPPORT=1
INSTALL_VSCODE=1
INSTALL_EDGE=1
INSTALL_FLATPAK=0
INSTALL_WECHAT=0
INSTALL_CLASH_VERGE_REV=0
INSTALL_ZOTERO=0
INSTALL_OBSIDIAN=0
INSTALL_GHOSTTY=0
INSTALL_MAPLE_FONT=0
INSTALL_MINIFORGE=0
INSTALL_NVIDIA=1

cleanup() {
  if [[ "${KEEP_STAGE2_PLAN:-0}" != "1" && -n "${PLAN_FILE:-}" && -f "${PLAN_FILE:-}" ]]; then
    rm -f "$PLAN_FILE"
  fi
  if [[ -n "${RESULT_LOG:-}" && -f "${RESULT_LOG:-}" ]]; then
    rm -f "$RESULT_LOG"
  fi
}
trap cleanup EXIT

usage() {
  cat <<'EOF'
Stage 2:
  - initialize snapper and create a fresh snapshot
  - remove snap/snapd or enforce a no-snap state on Debian/Ubuntu APT systems
  - run a non-interactive system upgrade
  - install selected packaged apps and managed apps
  - run cleanup and print a summary

Usage:
  manage.sh setup stage2 [--apply] [--yes] [--profile desktop|server] [-h|--help]

Options:
  --apply    Run stage 2 (prompts for profile and selections unless --yes is given)
  --yes      Use default selections and execute without prompting
  --check    Preview the stage2 order and the default selections (default)
  --profile  Set the install profile to desktop or server
EOF
}


apply_profile_defaults() {
  case "$INSTALL_PROFILE" in
    desktop)
      INSTALL_SHELL_ENV=1
      INSTALL_DESKTOP_ESSENTIALS=1
      INSTALL_CHINESE_SUPPORT=1
      INSTALL_VSCODE=1
      INSTALL_EDGE=1
      INSTALL_FLATPAK=0
      INSTALL_WECHAT=0
      INSTALL_CLASH_VERGE_REV=0
      INSTALL_ZOTERO=0
      INSTALL_OBSIDIAN=0
      INSTALL_GHOSTTY=0
      INSTALL_MAPLE_FONT=0
      INSTALL_MINIFORGE=0
      INSTALL_NVIDIA=1
      ;;
    server)
      INSTALL_SHELL_ENV=1
      INSTALL_DESKTOP_ESSENTIALS=0
      INSTALL_CHINESE_SUPPORT=0
      INSTALL_VSCODE=0
      INSTALL_EDGE=0
      INSTALL_FLATPAK=0
      INSTALL_WECHAT=0
      INSTALL_CLASH_VERGE_REV=0
      INSTALL_ZOTERO=0
      INSTALL_OBSIDIAN=0
      INSTALL_GHOSTTY=0
      INSTALL_MAPLE_FONT=0
      INSTALL_MINIFORGE=0
      INSTALL_NVIDIA=1
      ;;
    *)
      die "Unsupported install profile: $INSTALL_PROFILE"
      ;;
  esac
}

collect_profile_with_text() {
  local answer

  while true; do
    printf '%s' "Install profile [D]esktop/[s]erver: "
    read -r answer
    case "$answer" in
      ''|d|D|desktop|DESKTOP)
        INSTALL_PROFILE="desktop"
        return 0
        ;;
      s|S|server|SERVER)
        INSTALL_PROFILE="server"
        return 0
        ;;
      *)
        printf 'Please answer desktop or server.\n' >&2
        ;;
    esac
  done
}

collect_profile_with_whiptail() {
  INSTALL_PROFILE="$(
    whiptail \
      --title "Linux Setup Stage 2" \
      --radiolist "Select the install profile. Desktop keeps the current graphical defaults. Server keeps only the development-oriented shell defaults." \
      16 88 2 \
      "desktop" "Graphical desktop defaults" ON \
      "server" "Development-oriented server defaults" OFF \
      3>&1 1>&2 2>&3
  )" || die "Stage 2 profile selection cancelled."
}

collect_install_profile() {
  if [[ "$ASSUME_YES" -eq 1 ]]; then
    info "Using the ${INSTALL_PROFILE} profile because --yes was provided."
    return 0
  fi

  if [[ "$PROFILE_EXPLICIT" -eq 1 ]]; then
    info "Using the explicitly requested ${INSTALL_PROFILE} profile."
    return 0
  fi

  if ! has_interactive_tty; then
    die "Stage 2 profile selection needs an interactive terminal. Re-run in a terminal, or use --yes with --profile."
  fi

  if supports_whiptail_ui; then
    collect_profile_with_whiptail
  else
    collect_profile_with_text
  fi
}

print_selection_summary() {
  printf 'Selected stage2 items:\n'
  printf '  - profile=%s\n' "$INSTALL_PROFILE"
  component_print_lines "${SETUP_COMPONENTS[@]}"
}

reset_checklist_selection() {
  component_reset "${SETUP_COMPONENTS[@]}"
}

collect_selection_with_text() {
  local component variable
  printf '[INFO] Falling back to plain text prompts because a full-screen checklist is not available.\n'
  printf '[INFO] Text mode tips: press y/n then Enter for each item, press Ctrl+C to abort at any time.\n'

  for component in "${SETUP_COMPONENTS[@]}"; do
    variable="$(component_variable "$component")"
    prompt_bool_text "$variable" "$(component_prompt setup "$component")" "$(component_value "$component")"
  done
}

collect_selection_with_whiptail() {
  local selected_tags
  local -a checklist_args
  component_checklist_args checklist_args "${SETUP_COMPONENTS[@]}"

  selected_tags="$(
    whiptail \
      --title "Linux Setup Stage 2" \
      --checklist "Select what to install after the Fresh snapshot.\n\nKeys: ↑↓ move, Space toggle, Tab switch buttons, Enter confirm, Esc cancel." \
      24 90 14 \
      "${checklist_args[@]}" \
      3>&1 1>&2 2>&3
  )" || die "Stage 2 selection cancelled."

  reset_checklist_selection
  while [[ "$selected_tags" =~ \"([^\"]+)\" ]]; do
    component_set "${BASH_REMATCH[1]}" 1
    selected_tags="${selected_tags#*"${BASH_REMATCH[0]}"}"
  done
}

collect_stage2_selection() {
  if [[ "$ASSUME_YES" -eq 1 ]]; then
    info "Using the default stage2 selection because --yes was provided."
    return 0
  fi

  if ! has_interactive_tty; then
    die "Stage 2 selection needs an interactive terminal. Re-run in a terminal, or use --yes for the default selection."
  fi

  if supports_whiptail_ui; then
    collect_selection_with_whiptail
  else
    collect_selection_with_text
  fi
}

write_plan_file() {
  PLAN_FILE="/tmp/linux-setup-stage2-plan.$$".env
  {
    printf 'INSTALL_PROFILE=%s\n' "$INSTALL_PROFILE"
    component_write_env "${SETUP_COMPONENTS[@]}"
  } > "$PLAN_FILE"
}

run_fail_fast_step() {
  local step_id success_status message
  step_id="$1"
  success_status="$2"
  message="$3"
  shift 3

  info "$message"
  if "$@"; then
    record_result "$step_id" "$success_status" "$message"
  else
    record_result "$step_id" failed "$message"
    die "Stage 2 stopped because a required step failed: $step_id"
  fi
}

run_continue_step() {
  local step_id success_status message
  step_id="$1"
  success_status="$2"
  message="$3"
  shift 3

  info "$message"
  if "$@"; then
    record_result "$step_id" "$success_status" "$message"
  else
    warn "Step failed but stage2 will continue: $step_id"
    record_result "$step_id" failed "$message"
  fi
}

stage2_failed_count() {
  result_failed_count "$RESULT_LOG"
}

write_summary_file() {
  local reboot_required overall_result failed_count
  reboot_required="no"
  if [[ -f /var/run/reboot-required ]]; then
    reboot_required="yes"
  fi
  failed_count="$(stage2_failed_count)"
  overall_result="success"
  if preflight_has_errors; then
    overall_result="preflight_failed"
  elif [[ "$failed_count" -gt 0 ]]; then
    overall_result="completed_with_failures"
  fi

  {
    printf 'Linux Setup Stage 2 Summary\n'
    printf 'Generated: %s\n' "$(date -Iseconds)"
    printf 'Overall result: %s\n' "$overall_result"
    printf 'Log: %s\n' "$RUN_LOG"
    if [[ "${KEEP_STAGE2_PLAN:-0}" == "1" ]]; then
      printf 'Plan file: %s\n' "$PLAN_FILE"
    else
      printf 'Plan file: %s (removed on exit)\n' "$PLAN_FILE"
    fi
    printf 'Reboot required: %s\n' "$reboot_required"
    printf '\nPreflight:\n'
    if [[ "${#PREFLIGHT_LINES[@]}" -eq 0 ]]; then
      printf -- '- not run\n'
    else
      local entry level message
      for entry in "${PREFLIGHT_LINES[@]}"; do
        IFS='|' read -r level message <<< "$entry"
        printf -- '- %s: %s\n' "$level" "$message"
      done
    fi
    printf '\nSelected items:\n'
    printf -- '- profile: %s\n' "$INSTALL_PROFILE"
    local component
    for component in "${SETUP_COMPONENTS[@]}"; do
      printf -- '- %s: %s\n' "$component" "$(component_bool_label "$(component_value "$component")")"
    done
    printf '\nResults:\n'
    if [[ -f "$RESULT_LOG" ]]; then
      while IFS=$'\t' read -r step status message; do
        [[ -n "${step:-}" ]] || continue
        printf -- '- %s: %s' "$step" "$status"
        if [[ -n "${message:-}" ]]; then
          printf ' - %s' "$message"
        fi
        printf '\n'
      done < "$RESULT_LOG"
    fi
  } > "$SUMMARY_FILE"
}

show_check_preview() {
  local nvidia_preview
  nvidia_preview="$ROOT_DIR/drivers/nvidia/install-nvidia-cuda.sh --apply (only when nvidia=yes)"
  cat <<EOF
This was a check run. Stage 2 would execute in this order:

  1. $ROOT_DIR/tasks/system/bootstrap-snapper.sh --apply --baseline-desc "Fresh install (post subvolume split)"
  2. $ROOT_DIR/tasks/system/remove-snap.sh --apply
  3. $ROOT_DIR/tasks/system/upgrade-system.sh --apply
  4. $ROOT_DIR/tasks/system/install-base-tools.sh --apply
  5. $ROOT_DIR/tasks/shell/install-shell-environment.sh --apply --profile $INSTALL_PROFILE
  6. $ROOT_DIR/tasks/desktop/install-chinese-support.sh --apply
  7. $ROOT_DIR/tasks/apps/install-apt-apps.sh --apply --desktop-essentials $INSTALL_DESKTOP_ESSENTIALS --vscode $INSTALL_VSCODE --edge $INSTALL_EDGE
  8. $ROOT_DIR/tasks/apps/install-external-apps.sh --apply --flatpak $INSTALL_FLATPAK --wechat $INSTALL_WECHAT --clash-verge-rev $INSTALL_CLASH_VERGE_REV --zotero $INSTALL_ZOTERO --obsidian $INSTALL_OBSIDIAN --ghostty $INSTALL_GHOSTTY --maple-font $INSTALL_MAPLE_FONT --miniforge $INSTALL_MINIFORGE
  9. ${nvidia_preview}
 10. $ROOT_DIR/tasks/system/cleanup-system.sh --apply

At runtime, preflight will check sudo access, apt locks, free space, APT reachability, and GRUB preseed state.

Default selection:
EOF
  print_selection_summary
}

build_stage2_nvidia_args() {
  NVIDIA_ARGS=(--apply)
  if [[ "$ASSUME_YES" -eq 1 ]]; then
    NVIDIA_ARGS+=(--yes)
  fi
}

run_stage2_preflight() {
  preflight_reset
  preflight_check_supported_apt_distro
  preflight_check_btrfs_root
  preflight_check_sudo_access
  preflight_check_apt_locks
  preflight_check_root_free_space 2097152 4194304 "Stage 2"
  case "${DISTRO_ID:-unknown}" in
    ubuntu)
      preflight_check_network_access \
        "APT / distro mirror" \
        "https://archive.ubuntu.com" \
        "https://security.ubuntu.com"
      ;;
    debian)
      preflight_check_network_access \
        "APT / distro mirror" \
        "https://deb.debian.org" \
        "https://security.debian.org"
      ;;
    *)
      preflight_check_network_access \
        "APT / distro mirror" \
        "https://archive.ubuntu.com" \
        "https://security.ubuntu.com" \
        "https://deb.debian.org"
      ;;
  esac
  preflight_check_grub_preseed

  if [[ "$INSTALL_VSCODE" -eq 1 || "$INSTALL_EDGE" -eq 1 ]]; then
    preflight_check_optional_network_access \
      "Microsoft package repository" \
      "https://packages.microsoft.com"
  fi

  if [[ "$INSTALL_SHELL_ENV" -eq 1 ]]; then
    preflight_check_optional_network_access \
      "shell environment sources" \
      "https://starship.rs" \
      "https://github.com"
  fi

  if [[ "$INSTALL_FLATPAK" -eq 1 ]]; then
    preflight_check_optional_network_access \
      "Flathub services" \
      "https://flathub.org"
  fi

  if [[ "$INSTALL_WECHAT" -eq 1 ]]; then
    preflight_check_optional_network_access \
      "WeChat official download" \
      "https://dldir1v6.qq.com"
  fi

  if [[ "$INSTALL_CLASH_VERGE_REV" -eq 1 || "$INSTALL_OBSIDIAN" -eq 1 || "$INSTALL_GHOSTTY" -eq 1 || "$INSTALL_MAPLE_FONT" -eq 1 || "$INSTALL_MINIFORGE" -eq 1 ]]; then
    preflight_check_optional_network_access \
      "GitHub release services" \
      "https://api.github.com" \
      "https://github.com"
  fi

  if [[ "$INSTALL_ZOTERO" -eq 1 ]]; then
    preflight_check_optional_network_access \
      "Zotero third-party installer source" \
      "https://raw.githubusercontent.com"
  fi

  if [[ "$INSTALL_NVIDIA" -eq 1 ]]; then
    preflight_check_optional_network_access \
      "NVIDIA metadata and downloads" \
      "https://developer.nvidia.com" \
      "https://developer.download.nvidia.com" \
      "https://docs.nvidia.com"
  fi

  preflight_print_report
  ! preflight_has_errors
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes)
      ASSUME_YES=1
      RUN_MODE="apply"
      ;;
    --check)
      RUN_MODE="check"
      ;;
    --profile)
      [[ $# -ge 2 ]] || die "--profile requires a value"
      case "$2" in
        desktop|server)
          INSTALL_PROFILE="$2"
          PROFILE_EXPLICIT=1
          ;;
        *)
          die "--profile must be desktop or server"
          ;;
      esac
      shift
      ;;
    --apply)
      RUN_MODE="apply"
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

apply_profile_defaults

if [[ "$RUN_MODE" != "apply" ]]; then
  show_check_preview
  exit 0
fi

collect_install_profile
apply_profile_defaults
collect_stage2_selection
write_plan_file

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
CACHE_DIR="$HOME/.cache/linux-setup"
mkdir -p "$CACHE_DIR"

RUN_LOG="$CACHE_DIR/stage2.log"
SUMMARY_FILE="$CACHE_DIR/stage2-summary.txt"
RESULT_LOG="$CACHE_DIR/stage2-results.tsv"
touch "$RESULT_LOG"
export LINUX_SETUP_RESULT_LOG="$RESULT_LOG"

printf "\n====== RUN STARTS AT %s ======\n" "$TIMESTAMP" >> "$RUN_LOG"
exec > >(tee -a "$RUN_LOG") 2>&1

info "Stage 2 selection complete."
print_selection_summary
info "Temporary plan file: $PLAN_FILE"
info "Run log: $RUN_LOG"

ensure_sudo_session

if ! run_stage2_preflight; then
  write_summary_file
  die "Stage 2 stopped because preflight failed. Summary: $SUMMARY_FILE"
fi

run_fail_fast_step \
  snapper_fresh_snapshot \
  installed \
  "[1/10] Initialize snapper and create the Fresh snapshot" \
  bash "$ROOT_DIR/tasks/system/bootstrap-snapper.sh" --apply --baseline-desc "Fresh install (post subvolume split)"

run_fail_fast_step \
  desnap \
  updated \
  "[2/10] Remove snap/snapd or enforce a no-snap state" \
  bash "$ROOT_DIR/tasks/system/remove-snap.sh" --apply

run_fail_fast_step \
  system_upgrade \
  updated \
  "[3/10] Run a non-interactive system upgrade" \
  bash "$ROOT_DIR/tasks/system/upgrade-system.sh" --apply

run_fail_fast_step \
  base_tools \
  installed \
  "[4/10] Install base tools" \
  bash "$ROOT_DIR/tasks/system/install-base-tools.sh" --apply

if [[ "$INSTALL_SHELL_ENV" -eq 1 ]]; then
  run_continue_step \
    shell_env \
    installed \
    "[5/10] Install the shared shell environment and modern CLI tool bundle" \
    bash "$ROOT_DIR/tasks/shell/install-shell-environment.sh" --apply --profile "$INSTALL_PROFILE"
else
  record_result shell_env skipped_not_selected "Skipped by stage2 selection."
fi

if [[ "$INSTALL_CHINESE_SUPPORT" -eq 1 ]]; then
  run_continue_step \
    chinese_support \
    installed \
    "[6/10] Install Chinese support" \
    bash "$ROOT_DIR/tasks/desktop/install-chinese-support.sh" --apply
else
  record_result chinese_support skipped_not_selected "Skipped by stage2 selection."
fi

info "[7/10] Install selected packaged apps"
if ! bash "$ROOT_DIR/tasks/apps/install-apt-apps.sh" \
  --apply \
  --desktop-essentials "$INSTALL_DESKTOP_ESSENTIALS" \
  --vscode "$INSTALL_VSCODE" \
  --edge "$INSTALL_EDGE"; then
  warn "Packaged app script failed before it could finish recording per-item results."
  record_result apt_apps_runner failed "The packaged app installer exited unexpectedly."
fi

info "[8/10] Install selected managed apps"
if ! bash "$ROOT_DIR/tasks/apps/install-external-apps.sh" \
  --apply \
  --flatpak "$INSTALL_FLATPAK" \
  --wechat "$INSTALL_WECHAT" \
  --clash-verge-rev "$INSTALL_CLASH_VERGE_REV" \
  --zotero "$INSTALL_ZOTERO" \
  --obsidian "$INSTALL_OBSIDIAN" \
  --ghostty "$INSTALL_GHOSTTY" \
  --maple-font "$INSTALL_MAPLE_FONT" \
  --miniforge "$INSTALL_MINIFORGE"; then
  warn "Managed app script failed before it could finish recording per-item results."
  record_result external_apps_runner failed "The managed app installer exited unexpectedly."
fi

if [[ "$INSTALL_NVIDIA" -eq 1 ]]; then
  build_stage2_nvidia_args
  run_continue_step \
    nvidia \
    updated \
    "[9/10] Install the NVIDIA driver + CUDA stack" \
    bash "$ROOT_DIR/drivers/nvidia/install-nvidia-cuda.sh" "${NVIDIA_ARGS[@]}"
else
  record_result nvidia skipped_not_selected "Skipped by stage2 selection."
fi

run_continue_step \
  cleanup \
  updated \
  "[10/10] Run cleanup" \
  bash "$ROOT_DIR/tasks/system/cleanup-system.sh" --apply

write_summary_file

printf '\nStage 2 finished.\n'
printf 'Summary: %s\n' "$SUMMARY_FILE"
printf 'Log: %s\n' "$RUN_LOG"
printf '\n'
cat "$SUMMARY_FILE"

failed_count="$(stage2_failed_count)"
if [[ "$failed_count" -gt 0 ]]; then
  printf '\n'
  warn "Stage 2 completed with ${failed_count} failed step(s)."
  info "Summary kept at $SUMMARY_FILE"
  info "Log kept at $RUN_LOG"
  exit 1
fi

printf '\n'
info "Stage 2 execution completed successfully."

# In non-interactive or SSH-headless environments, read might return immediately. We set default to yes.
_del_logs="y"
if has_interactive_tty; then
  read -t 10 -p "Delete setup logs in $CACHE_DIR? [Y/n] (auto-yes in 10s): " _del_logs || echo
fi

if [[ -z "$_del_logs" || "$_del_logs" =~ ^[Yy]$ ]]; then
  rm -f "$RUN_LOG" "$SUMMARY_FILE" "$RESULT_LOG" "$PLAN_FILE"
  info "Logs cleaned up."
else
  info "Logs kept at $CACHE_DIR."
fi
