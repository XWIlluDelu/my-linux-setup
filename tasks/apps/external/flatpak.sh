#!/usr/bin/env bash

# Flatpak adapter.

flatpak_user_app_installed() {
  run_flatpak_user info --user "$1" >/dev/null 2>&1
}

ensure_flatpak_base_ready() {
  if [[ "$FLATPAK_BASE_READY" -eq 1 ]]; then
    return 0
  fi

  info "[flatpak] Ensure Flatpak is installed and configured"
  if ! install_packages flatpak; then
    return 1
  fi

  if ! command_exists flatpak; then
    return 1
  fi

  if ! as_root flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo; then
    return 1
  fi
  if ! run_flatpak_user remote-add --user --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo; then
    return 1
  fi
  if ! as_root flatpak config --system --set extra-languages "zh;zh_CN"; then
    return 1
  fi
  if ! run_flatpak_user config --user --set extra-languages "zh;zh_CN"; then
    return 1
  fi
  if ! run_flatpak_user override --user --filesystem=xdg-config/fontconfig:ro; then
    return 1
  fi
  if ! run_flatpak_user override --user \
    --env=GTK_IM_MODULE=fcitx \
    --env=QT_IM_MODULE=fcitx \
    --env=XMODIFIERS=@im=fcitx; then
    return 1
  fi
  if ! as_root flatpak update -y; then
    return 1
  fi
  if ! run_flatpak_user update --user -y; then
    return 1
  fi

  FLATPAK_BASE_READY=1
  return 0
}

install_flatpak_stack() {
  local flatpak_pkg_installed=0 flatseal_installed=0 status

  if [[ "$INSTALL_FLATPAK" -eq 0 ]]; then
    return 0
  fi

  if command_exists flatpak; then
    flatpak_pkg_installed=1
  fi

  if flatpak_user_app_installed com.github.tchx84.Flatseal; then
    flatseal_installed=1
  fi

  if ! ensure_flatpak_base_ready; then
    record_result flatpak failed "Failed to install or configure the Flatpak base workflow."
    return 0
  fi

  if ! run_flatpak_user install --user -y flathub com.github.tchx84.Flatseal; then
    record_result flatpak failed "Flatpak was configured, but Flatseal failed to install."
    return 0
  fi

  if [[ "$flatpak_pkg_installed" -eq 1 && "$flatseal_installed" -eq 1 ]]; then
    status="updated"
  else
    status="installed"
  fi
  record_result flatpak "$status" "Configured Flatpak (system and user Flathub remotes), Chinese settings, input method overrides, and Flatseal."
}
