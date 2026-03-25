#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
source "$ROOT_DIR/lib/common.sh"

SET_ALTERNATIVES=0

usage() {
  cat <<'EOF'
Configure Ghostty as the default terminal for common Linux desktop stacks.

Usage:
  ghostty-default-terminal.sh [--check] [--apply] [--set-alternatives]

Options:
  --check             Preview what would be changed (default)
  --apply             Apply user-level configuration changes
  --set-alternatives  Also set Debian/Ubuntu x-terminal-emulator when available

Notes:
  - This script is intentionally standalone under extras/ and does not modify manage.sh.
  - Run it as the desktop user whose file manager behavior you want to change.
  - The behavior is desktop/file-manager specific, not purely distro specific.
  - GNOME/Nautilus works best via xdg-terminal-exec when available.
  - KDE changes the default external terminal, not Dolphin's embedded terminal panel.
  - Cinnamon/Nemo support is best-effort only.
EOF
}

desktop_schema_exists() {
  local schema
  schema="$1"

  command_exists gsettings || return 1
  gsettings list-schemas 2>/dev/null | grep -Fxq "$schema"
}

session_bus_available() {
  [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]]
}

detect_ghostty_desktop_id() {
  local data_dir candidate
  local -a desktop_names=(
    com.mitchellh.ghostty.desktop
    ghostty.desktop
  )
  local -a search_dirs=("$HOME/.local/share/applications")

  if [[ -n "${XDG_DATA_HOME:-}" ]]; then
    search_dirs+=("$XDG_DATA_HOME/applications")
  fi

  while IFS= read -r data_dir; do
    [[ -n "$data_dir" ]] || continue
    search_dirs+=("$data_dir/applications")
  done < <(printf '%s\n' "${XDG_DATA_DIRS:-/usr/local/share:/usr/share}" | tr ':' '\n')

  for data_dir in "${search_dirs[@]}"; do
    for candidate in "${desktop_names[@]}"; do
      if [[ -f "$data_dir/$candidate" ]]; then
        printf '%s\n' "$candidate"
        return 0
      fi
    done
  done

  return 1
}

build_desktop_tokens() {
  local raw token sanitized seen
  raw="${XDG_CURRENT_DESKTOP:-}:${DESKTOP_SESSION:-}"
  seen=":"

  while IFS= read -r token; do
    token=${token,,}
    sanitized=$(printf '%s' "$token" | tr -cs 'a-z0-9._-' '-')
    sanitized=${sanitized#-}
    sanitized=${sanitized%-}
    [[ -n "$sanitized" ]] || continue
    case "$seen" in
      *":$sanitized:"*)
        continue
        ;;
    esac
    seen="$seen$sanitized:"
    printf '%s\n' "$sanitized"
  done < <(printf '%s\n' "$raw" | tr ':' '\n')
}

token_in_list() {
  local needle token
  needle="$1"
  shift
  for token in "$@"; do
    [[ "$token" == "$needle" ]] && return 0
  done
  return 1
}

write_single_line_file() {
  local path content
  path="$1"
  content="$2"

  if [[ "$APPLY" -eq 1 ]]; then
    mkdir -p "$(dirname "$path")"
    printf '%s\n' "$content" > "$path"
    info "Wrote $path"
  else
    info "[dry-run] write $path -> $content"
  fi
}

write_block_file() {
  local path content
  path="$1"
  content="$2"

  if [[ "$APPLY" -eq 1 ]]; then
    mkdir -p "$(dirname "$path")"
    printf '%s\n' "$content" > "$path"
    info "Wrote $path"
  else
    info "[dry-run] write $path"
  fi
}

clear_xdg_terminal_cache() {
  local cache_file
  cache_file="$HOME/.cache/xdg-terminal-exec"

  if [[ "$APPLY" -eq 1 ]]; then
    rm -f "$cache_file"
    info "Cleared $cache_file"
  else
    info "[dry-run] remove $cache_file"
  fi
}

set_xdg_terminal_exec_files() {
  local desktop_id token
  desktop_id="$1"
  shift

  write_single_line_file "$HOME/.config/xdg-terminals.list" "$desktop_id"
  for token in "$@"; do
    write_single_line_file "$HOME/.config/${token}-xdg-terminals.list" "$desktop_id"
  done
  clear_xdg_terminal_cache
}

set_nautilus_extension_terminal() {
  if ! desktop_schema_exists com.github.stunkymonkey.nautilus-open-any-terminal; then
    return 0
  fi
  if ! session_bus_available; then
    warn "nautilus-open-any-terminal is installed, but no user DBus session was detected; skipped gsettings write."
    return 0
  fi

  if [[ "$APPLY" -eq 1 ]]; then
    gsettings set com.github.stunkymonkey.nautilus-open-any-terminal terminal ghostty
    info "Configured nautilus-open-any-terminal -> ghostty"
  else
    info "[dry-run] gsettings set com.github.stunkymonkey.nautilus-open-any-terminal terminal ghostty"
  fi
}

set_kde_terminal() {
  local writer=""

  if command_exists kwriteconfig6; then
    writer="kwriteconfig6"
  elif command_exists kwriteconfig5; then
    writer="kwriteconfig5"
  else
    warn "KDE session detected, but kwriteconfig5/6 is missing; skipped KDE integration."
    return 0
  fi

  run "$writer" --file kdeglobals --group General --key TerminalApplication ghostty
  run "$writer" --file kdeglobals --group General --key TerminalService "$1"
}

set_xfce_terminal() {
  local helper_file helper_content
  helper_file="$HOME/.local/share/xfce4/helpers/custom-Ghostty.desktop"
  helper_content='[Desktop Entry]
Version=1.0
Type=X-XFCE-Helper
Name=Ghostty
X-XFCE-Category=TerminalEmulator
X-XFCE-Commands=ghostty
X-XFCE-CommandsWithParameter=ghostty --working-directory=%s'

  write_single_line_file "$HOME/.config/xfce4/helpers.rc" 'TerminalEmulator=custom-Ghostty'
  write_block_file "$helper_file" "$helper_content"
}

set_cinnamon_terminal() {
  if ! desktop_schema_exists org.cinnamon.desktop.default-applications.terminal; then
    warn "Cinnamon session detected, but org.cinnamon.desktop.default-applications.terminal is unavailable."
    return 0
  fi
  if ! session_bus_available; then
    warn "Cinnamon session detected without a user DBus session; skipped gsettings write."
    return 0
  fi

  if [[ "$APPLY" -eq 1 ]]; then
    gsettings set org.cinnamon.desktop.default-applications.terminal exec ghostty
    info "Configured Cinnamon default terminal -> ghostty"
  else
    info "[dry-run] gsettings set org.cinnamon.desktop.default-applications.terminal exec ghostty"
  fi

  warn "Nemo upstream may still ignore Ghostty for its built-in Open in Terminal action."
}

set_debian_alternatives() {
  local ghostty_bin
  ghostty_bin="$1"

  command_exists update-alternatives || return 0
  update-alternatives --query x-terminal-emulator >/dev/null 2>&1 || return 0

  if ! update-alternatives --list x-terminal-emulator 2>/dev/null | grep -Fxq "$ghostty_bin"; then
    warn "Ghostty is not registered in x-terminal-emulator alternatives; skipped."
    return 0
  fi

  if [[ "$APPLY" -eq 1 ]]; then
    ensure_sudo_session
  fi

  run_as_root update-alternatives --set x-terminal-emulator "$ghostty_bin"
}

print_summary() {
  local ghostty_bin desktop_id
  ghostty_bin="$1"
  desktop_id="$2"
  shift 2

  cat <<EOF
Detected:
  distro           : ${DISTRO_PRETTY:-unknown}
  session          : ${XDG_CURRENT_DESKTOP:-${DESKTOP_SESSION:-unknown}}
  ghostty binary   : $ghostty_bin
  ghostty desktop  : $desktop_id
  xdg-terminal-exec: $(if command_exists xdg-terminal-exec; then printf 'yes'; else printf 'no'; fi)
EOF

  if [[ $# -gt 0 ]]; then
    printf '  desktop tokens   : %s\n' "$*"
  fi
}

print_plan() {
  local desktop_id=""
  desktop_id="$1"
  shift
  local -a tokens=("$@")

  printf '\nPlan:\n'

  if command_exists xdg-terminal-exec; then
    printf '  - Write ~/.config/xdg-terminals.list -> %s\n' "$desktop_id"
    if [[ ${#tokens[@]} -gt 0 ]]; then
      printf '  - Write desktop-specific xdg-terminal-exec overrides for: %s\n' "${tokens[*]}"
    fi
  fi

  if desktop_schema_exists com.github.stunkymonkey.nautilus-open-any-terminal; then
    printf '  - Configure nautilus-open-any-terminal -> ghostty\n'
  fi

  if token_in_list kde "${tokens[@]}" || token_in_list plasma "${tokens[@]}"; then
    printf '  - Set KDE TerminalApplication/TerminalService in kdeglobals\n'
  fi

  if token_in_list xfce "${tokens[@]}" || token_in_list xubuntu "${tokens[@]}"; then
    printf '  - Write XFCE helper config under ~/.config/xfce4 and ~/.local/share/xfce4/helpers\n'
  fi

  if token_in_list cinnamon "${tokens[@]}" || token_in_list x-cinnamon "${tokens[@]}"; then
    printf '  - Set Cinnamon terminal gsettings (best-effort)\n'
  fi

  if [[ "$SET_ALTERNATIVES" -eq 1 ]]; then
    printf '  - Also set Debian/Ubuntu x-terminal-emulator when available\n'
  else
    printf '  - Do not touch Debian/Ubuntu x-terminal-emulator (enable with --set-alternatives)\n'
  fi
}

main() {
  local ghostty_bin desktop_id
  local -a desktop_tokens=()

  detect_os_release

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --check)
        APPLY=0
        ;;
      --apply)
        APPLY=1
        ;;
      --set-alternatives)
        SET_ALTERNATIVES=1
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

  ensure_command bash
  ghostty_bin="$(command -v ghostty || true)"
  [[ -n "$ghostty_bin" ]] || die "ghostty not found in PATH"

  desktop_id="$(detect_ghostty_desktop_id || true)"
  [[ -n "$desktop_id" ]] || die "Ghostty desktop file not found in XDG application directories"

  while IFS= read -r token; do
    [[ -n "$token" ]] || continue
    desktop_tokens+=("$token")
  done < <(build_desktop_tokens)

  print_summary "$ghostty_bin" "$desktop_id" "${desktop_tokens[@]}"
  print_plan "$desktop_id" "${desktop_tokens[@]}"

  if [[ "$APPLY" -ne 1 ]]; then
    printf '\nThis was a check run. Re-run with --apply to execute.\n'
    exit 0
  fi

  if command_exists xdg-terminal-exec; then
    info "Configuring xdg-terminal-exec defaults"
    set_xdg_terminal_exec_files "$desktop_id" "${desktop_tokens[@]}"
  fi

  set_nautilus_extension_terminal

  if token_in_list kde "${desktop_tokens[@]}" || token_in_list plasma "${desktop_tokens[@]}"; then
    info "Configuring KDE default terminal"
    set_kde_terminal "$desktop_id"
  fi

  if token_in_list xfce "${desktop_tokens[@]}" || token_in_list xubuntu "${desktop_tokens[@]}"; then
    info "Configuring XFCE preferred terminal"
    set_xfce_terminal
  fi

  if token_in_list cinnamon "${desktop_tokens[@]}" || token_in_list x-cinnamon "${desktop_tokens[@]}"; then
    info "Configuring Cinnamon default terminal"
    set_cinnamon_terminal
  fi

  if [[ "$SET_ALTERNATIVES" -eq 1 ]]; then
    info "Configuring Debian/Ubuntu x-terminal-emulator when available"
    set_debian_alternatives "$ghostty_bin"
  fi

  printf '\nDone. Verify with:\n'
  printf '  - xdg-terminal-exec --print-id\n'
  printf '  - xdg-terminal-exec --print-cmd --dir="$HOME"\n'
  printf '  - Reopen your file manager and test "Open in Terminal"\n'
}

main "$@"
