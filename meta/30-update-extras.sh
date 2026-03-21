#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
source "$ROOT_DIR/lib/common.sh"

RUN_MODE="check"
ASSUME_YES=0
RUN_LOG=""
SUMMARY_FILE=""
RESULT_LOG=""
TIMESTAMP=""
SHELL_ENV_MANAGED_DETECTED=0

INSTALL_SHELL_ENV=0
INSTALL_FLATPAK=0
INSTALL_WECHAT=0
INSTALL_CLASH_VERGE_REV=0
INSTALL_ZOTERO=0
INSTALL_OBSIDIAN=0
INSTALL_GHOSTTY=0
INSTALL_MAPLE_FONT=0
INSTALL_MINIFORGE=0
REDEPLOY_SHELL_CONFIG=0
MINIFORGE_PREFIX_OVERRIDE="${MINIFORGE_PREFIX:-}"
TARGET_USER=""
TARGET_HOME=""

cleanup() {
  if [[ -n "${RESULT_LOG:-}" && -f "${RESULT_LOG:-}" ]]; then
    rm -f "$RESULT_LOG"
  fi
}
trap cleanup EXIT

usage() {
  cat <<'EOF'
Install or update externally managed software and fonts.

Usage:
  30-update-extras.sh [--apply] [--yes] [-h|--help]

Options:
  --apply  Run install/update (interactive selection if TTY)
  --yes    Non-interactive mode: apply detected defaults only
  --check  Preview detected defaults and command plan (default)
EOF
}

detect_installed_wechat_deb() {
  if ! command_exists dpkg-query; then
    return 0
  fi

  dpkg-query -W -f='${Package}\t${Status}\n' 2>/dev/null \
    | awk '$4 == "installed" {print $1}' \
    | grep -E '^(wechat|weixin)(:|-|$)' \
    | head -n 1 || true
}

detect_update_pkg_manager() {
  detect_pkg_manager 2>/dev/null || true
}

package_installed_for_update_manager() {
  local package_name pm
  package_name="$1"
  pm="${2:-$(detect_update_pkg_manager)}"

  case "$pm" in
    apt-get)
      dpkg_package_installed "$package_name"
      ;;
    dnf|zypper)
      command_exists rpm || return 1
      rpm -q "$package_name" >/dev/null 2>&1
      ;;
    pacman)
      command_exists pacman || return 1
      pacman -Q "$package_name" >/dev/null 2>&1
      ;;
    *)
      return 1
      ;;
  esac
}

managed_zotero_tarball_installed() {
  [[ -x "$TARGET_HOME/.local/opt/zotero/zotero" ]]
}

managed_obsidian_appimage_installed() {
  [[ -x "$TARGET_HOME/.local/opt/obsidian/Obsidian.AppImage" ]]
}

external_backend_zotero() {
  if supports_debian_apt_workflow "$(detect_update_pkg_manager)"; then
    printf 'apt\n'
  else
    printf 'tarball\n'
  fi
}

external_backend_obsidian() {
  if supports_debian_apt_workflow "$(detect_update_pkg_manager)"; then
    printf 'apt\n'
  else
    printf 'appimage\n'
  fi
}

external_backend_clash_verge_rev() {
  case "$(detect_update_pkg_manager)" in
    apt-get)
      printf 'apt\n'
      ;;
    dnf|zypper)
      printf 'rpm\n'
      ;;
    pacman)
      printf 'aur\n'
      ;;
    *)
      printf 'unsupported\n'
      ;;
  esac
}

external_backend_ghostty() {
  local pm
  pm="$(detect_update_pkg_manager)"

  case "$pm" in
    apt-get)
      printf 'apt\n'
      ;;
    pacman)
      printf 'pacman\n'
      ;;
    dnf)
      detect_os_release
      if [[ "${DISTRO_ID:-unknown}" == "fedora" ]]; then
        printf 'dnf\n'
      else
        printf 'unsupported\n'
      fi
      ;;
    *)
      printf 'unsupported\n'
      ;;
  esac
}

flatpak_remote_exists() {
  local scope_flag="${1:-}"
  if [[ "$scope_flag" == "--user" ]]; then
    run_as_target_user "$TARGET_USER" "$TARGET_HOME" \
      flatpak remotes --user --columns=name 2>/dev/null | grep -qx 'flathub'
  else
    flatpak remotes --columns=name 2>/dev/null | grep -qx 'flathub'
  fi
}

detect_managed_flatpak_support() {
  command_exists flatpak || return 1

  run_as_target_user "$TARGET_USER" "$TARGET_HOME" \
    flatpak info --user com.github.tchx84.Flatseal >/dev/null 2>&1 && return 0
  flatpak_remote_exists "" && return 0
  flatpak_remote_exists --user && return 0
  return 1
}

detect_installed_extras() {
  local wechat_deb_pkg detected_miniforge_prefix update_pm

  if detect_managed_shell_env "$TARGET_HOME"; then
    SHELL_ENV_MANAGED_DETECTED=1
  fi

  update_pm="$(detect_update_pkg_manager)"

  if detect_managed_flatpak_support; then
    INSTALL_FLATPAK=1
  fi

  wechat_deb_pkg="$(detect_installed_wechat_deb)"
  if [[ -n "$wechat_deb_pkg" ]]; then
    INSTALL_WECHAT=1
  fi

  case "$(external_backend_clash_verge_rev)" in
    apt|rpm)
      if package_installed_for_update_manager clash-verge "$update_pm"; then
        INSTALL_CLASH_VERGE_REV=1
      fi
      ;;
    aur)
      if package_installed_for_update_manager clash-verge-rev-bin "$update_pm"; then
        INSTALL_CLASH_VERGE_REV=1
      fi
      ;;
  esac

  case "$(external_backend_zotero)" in
    apt)
      if dpkg_package_installed zotero; then
        INSTALL_ZOTERO=1
      fi
      ;;
    tarball)
      if managed_zotero_tarball_installed; then
        INSTALL_ZOTERO=1
      fi
      ;;
  esac

  case "$(external_backend_obsidian)" in
    apt)
      if dpkg_package_installed obsidian; then
        INSTALL_OBSIDIAN=1
      fi
      ;;
    appimage)
      if managed_obsidian_appimage_installed; then
        INSTALL_OBSIDIAN=1
      fi
      ;;
  esac

  case "$(external_backend_ghostty)" in
    apt|pacman|dnf)
      if package_installed_for_update_manager ghostty "$update_pm"; then
        INSTALL_GHOSTTY=1
      fi
      ;;
  esac

  if [[ -f "$TARGET_HOME/.local/share/fonts/MapleMono-NF-CN-unhinted/.release-tag" ]]; then
    INSTALL_MAPLE_FONT=1
  fi

  detected_miniforge_prefix="$(HOME="$TARGET_HOME" detect_installed_miniforge_prefix "$MINIFORGE_PREFIX_OVERRIDE" || true)"
  if [[ -n "$detected_miniforge_prefix" ]]; then
    INSTALL_MINIFORGE=1
  fi
}

bool_label() {
  if [[ "$1" -eq 1 ]]; then
    printf 'yes\n'
  else
    printf 'no\n'
  fi
}

has_selected_extras() {
  [[ "$INSTALL_SHELL_ENV" -eq 1 || "$INSTALL_FLATPAK" -eq 1 || "$INSTALL_WECHAT" -eq 1 || "$INSTALL_CLASH_VERGE_REV" -eq 1 || "$INSTALL_ZOTERO" -eq 1 || "$INSTALL_OBSIDIAN" -eq 1 || "$INSTALL_GHOSTTY" -eq 1 || "$INSTALL_MAPLE_FONT" -eq 1 || "$INSTALL_MINIFORGE" -eq 1 || "$REDEPLOY_SHELL_CONFIG" -eq 1 ]]
}

reset_selected_extras() {
  INSTALL_SHELL_ENV=0
  INSTALL_FLATPAK=0
  INSTALL_WECHAT=0
  INSTALL_CLASH_VERGE_REV=0
  INSTALL_ZOTERO=0
  INSTALL_OBSIDIAN=0
  INSTALL_GHOSTTY=0
  INSTALL_MAPLE_FONT=0
  INSTALL_MINIFORGE=0
  REDEPLOY_SHELL_CONFIG=0
}

set_selected_extra_from_tag() {
  case "$1" in
    shell_env)
      INSTALL_SHELL_ENV=1
      ;;
    flatpak)
      INSTALL_FLATPAK=1
      ;;
    wechat)
      INSTALL_WECHAT=1
      ;;
    clash_verge_rev)
      INSTALL_CLASH_VERGE_REV=1
      ;;
    zotero)
      INSTALL_ZOTERO=1
      ;;
    obsidian)
      INSTALL_OBSIDIAN=1
      ;;
    ghostty)
      INSTALL_GHOSTTY=1
      ;;
    maple_font)
      INSTALL_MAPLE_FONT=1
      ;;
    miniforge)
      INSTALL_MINIFORGE=1
      ;;
    redeploy_shell_config)
      REDEPLOY_SHELL_CONFIG=1
      ;;
  esac
}

print_current_selection() {
  cat <<EOF
Current selection:
  - shell_env=$(bool_label "$INSTALL_SHELL_ENV")
  - redeploy_shell_config=$(bool_label "$REDEPLOY_SHELL_CONFIG")
  - flatpak=$(bool_label "$INSTALL_FLATPAK")
  - wechat=$(bool_label "$INSTALL_WECHAT")
  - clash_verge_rev=$(bool_label "$INSTALL_CLASH_VERGE_REV")
  - zotero=$(bool_label "$INSTALL_ZOTERO")
  - obsidian=$(bool_label "$INSTALL_OBSIDIAN")
  - ghostty=$(bool_label "$INSTALL_GHOSTTY")
  - maple_font=$(bool_label "$INSTALL_MAPLE_FONT")
  - miniforge=$(bool_label "$INSTALL_MINIFORGE")
EOF
}

collect_selection_with_text() {
  printf '[INFO] Using plain text prompts for extra install/update selection.\n'
  printf '[INFO] Text mode tips: press y/n then Enter for each item, press Ctrl+C to abort at any time.\n'

  prompt_bool_text INSTALL_SHELL_ENV "Install/Update tmux+zsh shell environment assets, starship, and zinit?" "$INSTALL_SHELL_ENV"
  prompt_bool_text REDEPLOY_SHELL_CONFIG "Redeploy managed shell config files (.profile/.bashrc/.zshrc/.tmux.conf)?" 0
  prompt_bool_text INSTALL_FLATPAK "Install/Update Flatpak, Flathub settings, and Flatseal?" "$INSTALL_FLATPAK"
  prompt_bool_text INSTALL_WECHAT "Install/Update WeChat (official .deb)?" "$INSTALL_WECHAT"
  prompt_bool_text INSTALL_CLASH_VERGE_REV "Install/Update Clash Verge Rev (official distro path)?" "$INSTALL_CLASH_VERGE_REV"
  prompt_bool_text INSTALL_ZOTERO "Install/Update Zotero (zotero-deb on Debian/Ubuntu, official tarball elsewhere)?" "$INSTALL_ZOTERO"
  prompt_bool_text INSTALL_OBSIDIAN "Install/Update Obsidian (official .deb on Debian/Ubuntu, official AppImage elsewhere)?" "$INSTALL_OBSIDIAN"
  prompt_bool_text INSTALL_GHOSTTY "Install/Update Ghostty (official-doc distro path)?" "$INSTALL_GHOSTTY"
  prompt_bool_text INSTALL_MAPLE_FONT "Install/Update Maple Mono NF CN unhinted?" "$INSTALL_MAPLE_FONT"
  prompt_bool_text INSTALL_MINIFORGE "Install/Update Miniforge?" "$INSTALL_MINIFORGE"
}

collect_selection_with_whiptail() {
  local selected_tags=()
  local -a args=()

  args+=("shell_env" "tmux/zsh/starship/zinit components and state" "$( [[ "$INSTALL_SHELL_ENV" -eq 1 ]] && printf ON || printf OFF )")
  args+=("redeploy_shell_config" "Overwrite managed .profile/.bashrc/.zshrc/.tmux.conf" OFF)
  args+=("flatpak" "Flatpak + Flathub + Flatseal + CJK settings" "$( [[ "$INSTALL_FLATPAK" -eq 1 ]] && printf ON || printf OFF )")
  args+=("wechat" "WeChat official .deb package" "$( [[ "$INSTALL_WECHAT" -eq 1 ]] && printf ON || printf OFF )")
  args+=("clash_verge_rev" "Clash Verge Rev via the official distro path" "$( [[ "$INSTALL_CLASH_VERGE_REV" -eq 1 ]] && printf ON || printf OFF )")
  args+=("zotero" "Zotero via zotero-deb or the official tarball" "$( [[ "$INSTALL_ZOTERO" -eq 1 ]] && printf ON || printf OFF )")
  args+=("obsidian" "Obsidian via the official .deb or AppImage" "$( [[ "$INSTALL_OBSIDIAN" -eq 1 ]] && printf ON || printf OFF )")
  args+=("ghostty" "Ghostty terminal via the official-doc distro path + managed config" "$( [[ "$INSTALL_GHOSTTY" -eq 1 ]] && printf ON || printf OFF )")
  args+=("maple_font" "Maple Mono NF CN unhinted font (user scope)" "$( [[ "$INSTALL_MAPLE_FONT" -eq 1 ]] && printf ON || printf OFF )")
  args+=("miniforge" "Miniforge in hidden user home prefix" "$( [[ "$INSTALL_MINIFORGE" -eq 1 ]] && printf ON || printf OFF )")

  selected_tags=(
    $(
      whiptail \
        --title "Linux Setup Extra Updates" \
        --checklist "Select what to install/update.\n\nKeys: ↑↓ move, Space toggle, Tab switch buttons, Enter confirm, Esc cancel." \
        18 88 8 \
        "${args[@]}" \
        3>&1 1>&2 2>&3
    )
  ) || die "Extra update selection cancelled."

  reset_selected_extras
  while [[ "${#selected_tags[@]}" -gt 0 ]]; do
    set_selected_extra_from_tag "${selected_tags[0]//\"/}"
    selected_tags=("${selected_tags[@]:1}")
  done
}

collect_update_selection() {
  if [[ "$ASSUME_YES" -eq 1 ]]; then
    info "Using detected defaults because --yes was provided."
    return 0
  fi

  if ! has_interactive_tty; then
    info "No interactive terminal detected. Updating all detected extras."
    return 0
  fi

  if supports_whiptail_ui; then
    collect_selection_with_whiptail
  else
    collect_selection_with_text
  fi
}

selected_updates_need_sudo() {
  if [[ "$INSTALL_FLATPAK" -eq 1 || "$INSTALL_WECHAT" -eq 1 || "$INSTALL_CLASH_VERGE_REV" -eq 1 || "$INSTALL_GHOSTTY" -eq 1 ]]; then
    return 0
  fi

  if [[ "$INSTALL_ZOTERO" -eq 1 && "$(external_backend_zotero)" == "apt" ]]; then
    return 0
  fi

  if [[ "$INSTALL_OBSIDIAN" -eq 1 && "$(external_backend_obsidian)" == "apt" ]]; then
    return 0
  fi

  if [[ "$INSTALL_SHELL_ENV" -eq 1 ]]; then
    if [[ "$SHELL_ENV_MANAGED_DETECTED" -ne 1 || "$(id -un)" != "$TARGET_USER" ]]; then
      return 0
    fi
  fi

  return 1
}

selected_updates_need_apt_workflow() {
  if ! supports_debian_apt_workflow "$(detect_update_pkg_manager)"; then
    return 1
  fi

  [[ "$INSTALL_WECHAT" -eq 1 || "$INSTALL_CLASH_VERGE_REV" -eq 1 || "$INSTALL_ZOTERO" -eq 1 || "$INSTALL_OBSIDIAN" -eq 1 || "$INSTALL_GHOSTTY" -eq 1 ]]
}

selected_updates_need_package_manager() {
  if [[ "$INSTALL_SHELL_ENV" -eq 1 || "$INSTALL_FLATPAK" -eq 1 || "$INSTALL_CLASH_VERGE_REV" -eq 1 || "$INSTALL_GHOSTTY" -eq 1 ]]; then
    return 0
  fi

  if [[ "$INSTALL_ZOTERO" -eq 1 && "$(external_backend_zotero)" == "apt" ]]; then
    return 0
  fi

  if [[ "$INSTALL_OBSIDIAN" -eq 1 && "$(external_backend_obsidian)" == "apt" ]]; then
    return 0
  fi

  return 1
}

run_extra_update_preflight() {
  preflight_reset
  if selected_updates_need_apt_workflow; then
    preflight_check_supported_apt_distro
  elif selected_updates_need_package_manager; then
    preflight_check_supported_package_manager
  else
    preflight_ok "No package-manager-bound extra updates were selected."
  fi
  if selected_updates_need_sudo; then
    preflight_check_sudo_access
  else
    preflight_ok "No sudo-managed extra updates were selected."
  fi
  if selected_updates_need_apt_workflow; then
    preflight_check_apt_locks
  else
    preflight_ok "No apt-managed extra updates were selected, so apt lock checks were skipped."
  fi
  preflight_check_root_free_space 1048576 2097152 "Extra updates"
  preflight_check_network_access \
    "general network access" \
    "https://archive.ubuntu.com" \
    "https://deb.debian.org" \
    "https://github.com"

  if [[ "$INSTALL_WECHAT" -eq 1 ]]; then
    preflight_check_optional_network_access \
      "WeChat official download" \
      "https://dldir1v6.qq.com/weixin/Universal/Linux/WeChatLinux_x86_64.deb"
  fi

  if [[ "$INSTALL_FLATPAK" -eq 1 ]]; then
    preflight_check_optional_network_access \
      "Flathub services" \
      "https://flathub.org"
  fi

  if [[ "$INSTALL_CLASH_VERGE_REV" -eq 1 || "$INSTALL_OBSIDIAN" -eq 1 || "$INSTALL_GHOSTTY" -eq 1 || "$INSTALL_MAPLE_FONT" -eq 1 || "$INSTALL_MINIFORGE" -eq 1 ]]; then
    preflight_check_optional_network_access \
      "GitHub release services" \
      "https://api.github.com" \
      "https://github.com"
  fi

  if [[ "$INSTALL_ZOTERO" -eq 1 ]]; then
    if [[ "$(external_backend_zotero)" == "apt" ]]; then
      preflight_check_optional_network_access \
        "Zotero third-party installer source" \
        "https://raw.githubusercontent.com"
    else
      preflight_check_optional_network_access \
        "Zotero official download" \
        "https://www.zotero.org/download/" \
        "https://download.zotero.org"
    fi
  fi

  if [[ "$INSTALL_SHELL_ENV" -eq 1 ]]; then
    preflight_check_optional_network_access \
      "shell environment sources" \
      "https://starship.rs" \
      "https://github.com"
  fi

  preflight_print_report
  ! preflight_has_errors
}

extra_update_failed_count() {
  if [[ ! -f "${RESULT_LOG:-}" ]]; then
    printf '0\n'
    return 0
  fi
  awk -F'\t' '$2=="failed" {count++} END {print count+0}' "$RESULT_LOG"
}

write_summary_file() {
  local overall_result failed_count
  failed_count="$(extra_update_failed_count)"
  overall_result="success"
  if preflight_has_errors; then
    overall_result="preflight_failed"
  elif [[ "$failed_count" -gt 0 ]]; then
    overall_result="completed_with_failures"
  fi

  {
    printf 'Linux Setup Extra Update Summary\n'
    printf 'Generated: %s\n' "$(date -Iseconds)"
    printf 'Overall result: %s\n' "$overall_result"
    printf 'Log: %s\n' "$RUN_LOG"
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
    printf '\n'
    print_current_selection
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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)
      RUN_MODE="check"
      ;;
    --yes)
      ASSUME_YES=1
      RUN_MODE="apply"
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

TARGET_USER="$(resolve_target_user)"
TARGET_HOME="$(resolve_target_home "$TARGET_USER")"
detect_installed_extras

if [[ "$RUN_MODE" != "apply" ]]; then
  printf 'This was a check run. The meta script would execute:\n\n'
  printf '  1. %s/steps/45-shell-environment.sh --apply --update-only (shell_env=%s)\n' \
    "$ROOT_DIR" \
    "$INSTALL_SHELL_ENV"
  printf '  2. %s/steps/65-external-apps.sh --apply --flatpak %s --wechat %s --clash-verge-rev %s --zotero %s --obsidian %s --ghostty %s --maple-font %s --miniforge %s\n' \
    "$ROOT_DIR" \
    "$INSTALL_FLATPAK" \
    "$INSTALL_WECHAT" \
    "$INSTALL_CLASH_VERGE_REV" \
    "$INSTALL_ZOTERO" \
    "$INSTALL_OBSIDIAN" \
    "$INSTALL_GHOSTTY" \
    "$INSTALL_MAPLE_FONT" \
    "$INSTALL_MINIFORGE"
  printf '\nAt runtime, preflight will check free space and network reachability, plus package-manager-specific readiness when the selected updates need it; sudo is only required when the selected updates need it.\n\n'
  print_current_selection
  exit 0
fi

collect_update_selection

if ! has_selected_extras; then
  info "No software was selected for install/update."
  exit 0
fi

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
CACHE_DIR="$TARGET_HOME/.cache/linux-setup"
mkdir -p "$CACHE_DIR"

RUN_LOG="$CACHE_DIR/update-extras.log"
SUMMARY_FILE="$CACHE_DIR/update-extras-summary.txt"
RESULT_LOG="$CACHE_DIR/update-extras-results.tsv"
touch "$RESULT_LOG"
export STAGE2_RESULT_LOG="$RESULT_LOG"

printf "\n====== RUN STARTS AT %s ======\n" "$TIMESTAMP" >> "$RUN_LOG"
exec > >(tee -a "$RUN_LOG") 2>&1

info "Updating selected externally managed software."
  print_current_selection

if selected_updates_need_sudo; then
  ensure_sudo_session
fi

if ! run_extra_update_preflight; then
  write_summary_file
  die "Extra update stopped because preflight failed. Summary: $SUMMARY_FILE"
fi

if [[ "$INSTALL_SHELL_ENV" -eq 1 ]]; then
  local_profile="$(shell_env_profile_from_state_or_marker "$TARGET_HOME" 2>/dev/null || echo desktop)"
  if [[ "$SHELL_ENV_MANAGED_DETECTED" -eq 1 ]]; then
    shell_env_args=(--apply --update-only --profile "$local_profile")
  else
    shell_env_args=(--apply --profile "$local_profile")
  fi

  if ! run_as_target_user "$TARGET_USER" "$TARGET_HOME" \
    bash "$ROOT_DIR/steps/45-shell-environment.sh" \
    "${shell_env_args[@]}"; then
    warn "The shell environment update step exited unexpectedly."
    record_stage2_result shell_env failed "The shell environment update step exited unexpectedly."
  else
    record_stage2_result shell_env updated "Shell environment components refreshed."
  fi
fi

if [[ "$REDEPLOY_SHELL_CONFIG" -eq 1 ]]; then
  info "Redeploying shell configuration files..."
  local_profile="$(shell_env_profile_from_state_or_marker "$TARGET_HOME" 2>/dev/null || echo desktop)"
  if ! run_as_target_user "$TARGET_USER" "$TARGET_HOME" \
    bash "$ROOT_DIR/tools/deploy-shell-config.sh" \
    --apply \
    --profile "$local_profile"; then
    warn "Shell config redeploy exited unexpectedly."
    record_stage2_result redeploy_shell_config failed "Shell config redeploy exited unexpectedly."
  else
    record_stage2_result redeploy_shell_config ok "Shell configuration files redeployed."
  fi
fi

if ! run_as_target_user "$TARGET_USER" "$TARGET_HOME" \
  bash "$ROOT_DIR/steps/65-external-apps.sh" \
  --apply \
  --flatpak "$INSTALL_FLATPAK" \
  --wechat "$INSTALL_WECHAT" \
  --clash-verge-rev "$INSTALL_CLASH_VERGE_REV" \
  --zotero "$INSTALL_ZOTERO" \
  --obsidian "$INSTALL_OBSIDIAN" \
  --ghostty "$INSTALL_GHOSTTY" \
  --maple-font "$INSTALL_MAPLE_FONT" \
  --miniforge "$INSTALL_MINIFORGE"; then
  warn "The external software update step exited unexpectedly."
  record_stage2_result external_update_runner failed "The external software update runner exited unexpectedly."
fi

write_summary_file

printf '\nExtra update finished.\n'
printf 'Summary: %s\n' "$SUMMARY_FILE"
printf 'Log: %s\n' "$RUN_LOG"
printf '\n'
cat "$SUMMARY_FILE"

failed_count="$(extra_update_failed_count)"
if [[ "$failed_count" -gt 0 ]]; then
  printf '\n'
  warn "Extra update completed with ${failed_count} failed step(s)."
  info "Summary kept at $SUMMARY_FILE"
  info "Log kept at $RUN_LOG"
  exit 1
fi

printf '\n'
info "Extra update completed successfully."

# In non-interactive or SSH-headless environments, read might return immediately. We set default to yes.
_del_logs="y"
if has_interactive_tty; then
  read -t 10 -p "Delete setup logs in $CACHE_DIR? [Y/n] (auto-yes in 10s): " _del_logs || echo
fi

if [[ -z "$_del_logs" || "$_del_logs" =~ ^[Yy]$ ]]; then
  rm -f "$RUN_LOG" "$SUMMARY_FILE" "$RESULT_LOG"
  info "Logs cleaned up."
else
  info "Logs kept at $CACHE_DIR."
fi
