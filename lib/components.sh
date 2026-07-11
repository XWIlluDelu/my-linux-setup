#!/usr/bin/env bash

# Single authority for selectable setup and managed-update components.

declare -ar SETUP_COMPONENTS=(
  shell_env
  desktop_essentials
  chinese_support
  vscode
  edge
  flatpak
  wechat
  clash_verge_rev
  zotero
  obsidian
  ghostty
  maple_font
  miniforge
  nvidia
)

declare -ar UPDATE_COMPONENTS=(
  shell_env
  redeploy_shell_config
  desktop_essentials
  vscode
  edge
  flatpak
  wechat
  clash_verge_rev
  zotero
  obsidian
  ghostty
  maple_font
  miniforge
)

declare -ar PACKAGED_APP_COMPONENTS=(desktop_essentials vscode edge)
declare -ar MANAGED_APP_COMPONENTS=(flatpak wechat clash_verge_rev zotero obsidian ghostty maple_font miniforge)

declare -Ar COMPONENT_VARIABLE=(
  [shell_env]=INSTALL_SHELL_ENV
  [redeploy_shell_config]=REDEPLOY_SHELL_CONFIG
  [desktop_essentials]=INSTALL_DESKTOP_ESSENTIALS
  [chinese_support]=INSTALL_CHINESE_SUPPORT
  [vscode]=INSTALL_VSCODE
  [edge]=INSTALL_EDGE
  [flatpak]=INSTALL_FLATPAK
  [wechat]=INSTALL_WECHAT
  [clash_verge_rev]=INSTALL_CLASH_VERGE_REV
  [zotero]=INSTALL_ZOTERO
  [obsidian]=INSTALL_OBSIDIAN
  [ghostty]=INSTALL_GHOSTTY
  [maple_font]=INSTALL_MAPLE_FONT
  [miniforge]=INSTALL_MINIFORGE
  [nvidia]=INSTALL_NVIDIA
)

declare -Ar COMPONENT_DESCRIPTION=(
  [shell_env]='zsh/tmux + modern CLI tools + starship/zinit + managed shell state'
  [redeploy_shell_config]='overwrite managed shell configuration files'
  [desktop_essentials]='mpv + wl-clipboard + Tweaks + Extension Manager'
  [chinese_support]='fcitx5 + Rime + Simplified Chinese font preference'
  [vscode]='Visual Studio Code from the Microsoft repository'
  [edge]='Microsoft Edge from the Microsoft repository'
  [flatpak]='Flatpak + Flathub + Flatseal + CJK settings'
  [wechat]='WeChat official .deb package'
  [clash_verge_rev]='Clash Verge Rev via the official distro path'
  [zotero]='Zotero via zotero-deb or the official tarball'
  [obsidian]='Obsidian via the official .deb or AppImage'
  [ghostty]='Ghostty via the official-doc distro path + managed config'
  [maple_font]='Maple Mono NF CN unhinted font (user scope)'
  [miniforge]='Miniforge in a hidden user-home prefix'
  [nvidia]='interactive NVIDIA driver + CUDA installer'
)

declare -Ar COMPONENT_SETUP_PROMPT=(
  [shell_env]='Install the managed shell environment and modern CLI tools?'
  [desktop_essentials]='Install desktop essentials?'
  [chinese_support]='Install Chinese input and font support?'
  [vscode]='Install Visual Studio Code?'
  [edge]='Install Microsoft Edge?'
  [flatpak]='Install Flatpak, Flathub settings, and Flatseal?'
  [wechat]='Install WeChat?'
  [clash_verge_rev]='Install Clash Verge Rev?'
  [zotero]='Install Zotero?'
  [obsidian]='Install Obsidian?'
  [ghostty]='Install Ghostty?'
  [maple_font]='Install Maple Mono NF CN unhinted?'
  [miniforge]='Install Miniforge?'
  [nvidia]='Launch the NVIDIA driver + CUDA installer at the end?'
)

declare -Ar COMPONENT_UPDATE_PROMPT=(
  [shell_env]='Install/update the managed shell environment and modern CLI tools?'
  [redeploy_shell_config]='Redeploy managed shell configuration files?'
  [desktop_essentials]='Install/update desktop essentials?'
  [vscode]='Install/update Visual Studio Code?'
  [edge]='Install/update Microsoft Edge?'
  [flatpak]='Install/update Flatpak, Flathub settings, and Flatseal?'
  [wechat]='Install/update WeChat?'
  [clash_verge_rev]='Install/update Clash Verge Rev?'
  [zotero]='Install/update Zotero?'
  [obsidian]='Install/update Obsidian?'
  [ghostty]='Install/update Ghostty?'
  [maple_font]='Install/update Maple Mono NF CN unhinted?'
  [miniforge]='Install/update Miniforge?'
)

component_variable() {
  [[ -n "${COMPONENT_VARIABLE[$1]:-}" ]] || return 1
  printf '%s\n' "${COMPONENT_VARIABLE[$1]}"
}

component_value() {
  local variable
  variable="$(component_variable "$1")" || return 1
  printf '%s\n' "${!variable:-0}"
}

component_set() {
  local variable value
  variable="$(component_variable "$1")" || die "Unknown component: $1"
  value="$2"
  [[ "$value" == 0 || "$value" == 1 ]] || die "Component values must be 0 or 1: $1=$value"
  printf -v "$variable" '%s' "$value"
}

component_reset() {
  local component
  for component in "$@"; do
    component_set "$component" 0
  done
}

component_any_selected() {
  local component
  for component in "$@"; do
    [[ "$(component_value "$component")" == 1 ]] && return 0
  done
  return 1
}

component_bool_label() {
  if [[ "$1" == 1 ]]; then
    printf 'yes\n'
  else
    printf 'no\n'
  fi
}

component_on_off() {
  if [[ "$(component_value "$1")" == 1 ]]; then
    printf 'ON\n'
  else
    printf 'OFF\n'
  fi
}

component_prompt() {
  local mode component
  mode="$1"
  component="$2"
  case "$mode" in
    setup) printf '%s\n' "${COMPONENT_SETUP_PROMPT[$component]}" ;;
    update) printf '%s\n' "${COMPONENT_UPDATE_PROMPT[$component]}" ;;
    *) return 1 ;;
  esac
}

component_print_lines() {
  local component
  for component in "$@"; do
    printf '  - %s=%s\n' "$component" "$(component_bool_label "$(component_value "$component")")"
  done
}

component_checklist_args() {
  local output_name component
  output_name="$1"
  shift
  local -n output="$output_name"
  output=()
  for component in "$@"; do
    output+=(
      "$component"
      "${COMPONENT_DESCRIPTION[$component]}"
      "$(component_on_off "$component")"
    )
  done
}

component_write_env() {
  local component variable
  for component in "$@"; do
    variable="$(component_variable "$component")"
    printf '%s=%s\n' "$variable" "$(component_value "$component")"
  done
}
