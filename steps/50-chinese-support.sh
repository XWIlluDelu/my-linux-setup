#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

RIME_ICE_REPO="https://github.com/iDvel/rime-ice.git"
RIME_DIR="$HOME/.local/share/fcitx5/rime"
FONTCONFIG_DIR="$HOME/.config/fontconfig/conf.d"
FONTCONFIG_FILE="$FONTCONFIG_DIR/99-noto-cjk-default-prefer-sc.conf"
TMP_DIR=""

cleanup() {
  if [[ -n "${TMP_DIR:-}" && -d "${TMP_DIR:-}" ]]; then
    rm -rf "$TMP_DIR"
  fi
}
trap cleanup EXIT

usage() {
  cat <<'EOF'
Install Chinese support:
  - Noto CJK fonts
  - fontconfig preference for SC glyphs
  - fcitx5 + rime
  - rime-ice

Usage:
  50-chinese-support.sh [--check] [--apply]

Notes:
  - Default mode is --check.
  - Supports apt, dnf, zypper, and pacman with distro-specific package mappings.
EOF
}

PKG_MANAGER="$(detect_pkg_manager 2>/dev/null || true)"
[[ -n "$PKG_MANAGER" ]] || die "No supported package manager detected. Supported: apt, dnf, zypper, pacman."

chinese_support_required_packages() {
  case "$PKG_MANAGER" in
    apt-get)
      printf '%s\n' \
        fcitx5 \
        fcitx5-config-qt \
        fcitx5-frontend-gtk3 \
        fcitx5-frontend-gtk4 \
        fcitx5-frontend-qt5 \
        fcitx5-rime \
        fontconfig \
        fonts-noto-cjk \
        fonts-noto-color-emoji \
        fonts-noto-core \
        git \
        im-config \
        rsync
      ;;
    dnf)
      printf '%s\n' \
        fcitx5 \
        fcitx5-autostart \
        fcitx5-configtool \
        fcitx5-gtk \
        fcitx5-qt \
        fcitx5-chinese-addons \
        fontconfig \
        google-noto-sans-cjk-fonts \
        google-noto-color-emoji-fonts \
        git \
        rsync
      ;;
    zypper)
      printf '%s\n' \
        fcitx5 \
        fcitx5-configtool \
        fcitx5-gtk3 \
        fcitx5-gtk4 \
        fcitx5-qt5 \
        fcitx5-chinese-addons \
        fontconfig \
        google-noto-sans-cjk-fonts \
        google-noto-coloremoji-fonts \
        git \
        rsync
      ;;
    pacman)
      printf '%s\n' \
        fcitx5 \
        fcitx5-configtool \
        fcitx5-gtk \
        fcitx5-qt \
        fcitx5-chinese-addons \
        fontconfig \
        jack2 \
        noto-fonts-cjk \
        noto-fonts-emoji \
        git \
        rsync
      ;;
  esac
}

chinese_support_optional_packages() {
  case "$PKG_MANAGER" in
    apt-get)
      printf '%s\n' fcitx5-frontend-qt6 fonts-noto-extra fonts-noto-ui-core
      ;;
    dnf)
      printf '%s\n' google-noto-sans-fonts google-noto-serif-fonts
      ;;
    zypper)
      printf '%s\n' google-noto-fonts
      ;;
    pacman)
      printf '%s\n' noto-fonts
      ;;
  esac
}

join_lines_csv() {
  tr '\n' ',' | sed 's/,$//' | sed 's/,/, /g'
}

collect_available_chinese_packages() {
  local pkg

  PACKAGES=()
  while IFS= read -r pkg; do
    [[ -n "$pkg" ]] || continue
    if package_available "$pkg" "$PKG_MANAGER"; then
      PACKAGES+=("$pkg")
    else
      warn "Package not available via $(package_manager_label "$PKG_MANAGER"), skipped: $pkg"
    fi
  done < <(chinese_support_required_packages)

  while IFS= read -r pkg; do
    [[ -n "$pkg" ]] || continue
    if package_available "$pkg" "$PKG_MANAGER"; then
      PACKAGES+=("$pkg")
    else
      warn "Optional package not available via $(package_manager_label "$PKG_MANAGER"), skipped: $pkg"
    fi
  done < <(chinese_support_optional_packages)
}

set_input_method_framework() {
  if command_exists im-config; then
    im-config -n fcitx5
    return 0
  fi

  if command_exists imsettings-switch; then
    imsettings-switch fcitx5 >/dev/null 2>&1 || \
      warn "imsettings-switch could not set fcitx5; session environment files were still written."
    return 0
  fi

  warn "No distro input-method switch helper was available; relying on the session environment files."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)
      APPLY=0
      ;;
    --apply)
      APPLY=1
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

ensure_command sudo

if [[ "$APPLY" -ne 1 ]]; then
  cat <<EOF
This was a check run. The script would:
  1. Refresh package metadata via $(package_manager_label "$PKG_MANAGER")
  2. Install Chinese input/font packages using the $(package_manager_label "$PKG_MANAGER") package mapping
  3. Prefer Simplified Chinese CJK glyphs via fontconfig
  4. Set fcitx5 as the input method framework when a distro helper is available
  5. Write GNOME Wayland-friendly Fcitx session environment and GTK config
  6. Clone and install rime-ice
  7. Write rime_ice as the default schema
  8. Apply custom Fcitx5 configurations (UI, shortcuts, cursor fix)
  9. Refresh font cache
  10. Print quick checks

Available package list for this host:
  - $(chinese_support_required_packages | join_lines_csv)
Optional packages will be installed when available:
  - $(chinese_support_optional_packages | join_lines_csv)

Run with --apply to execute.
EOF
  exit 0
fi

ensure_sudo_session

info "[1/10] Refresh package metadata via $(package_manager_label "$PKG_MANAGER")"
refresh_package_metadata

collect_available_chinese_packages
[[ "${#PACKAGES[@]}" -gt 0 ]] || die "No Chinese support packages were available via $(package_manager_label "$PKG_MANAGER")."

info "[2/10] Install fonts, fcitx5, rime, and required tools"
install_packages "${PACKAGES[@]}"

info "[3/10] Prefer Simplified Chinese CJK glyphs"
mkdir -p "$FONTCONFIG_DIR"
cat > "$FONTCONFIG_FILE" <<'EOF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
  <alias>
    <family>sans-serif</family>
    <prefer>
      <family>Noto Sans CJK SC</family>
      <family>Noto Sans CJK TC</family>
      <family>Noto Sans CJK JP</family>
      <family>Noto Sans CJK KR</family>
    </prefer>
  </alias>

  <alias>
    <family>serif</family>
    <prefer>
      <family>Noto Serif CJK SC</family>
      <family>Noto Serif CJK TC</family>
      <family>Noto Serif CJK JP</family>
      <family>Noto Serif CJK KR</family>
    </prefer>
  </alias>

  <alias>
    <family>monospace</family>
    <prefer>
      <family>Noto Sans Mono CJK SC</family>
      <family>Noto Sans Mono CJK TC</family>
      <family>Noto Sans Mono CJK JP</family>
      <family>Noto Sans Mono CJK KR</family>
    </prefer>
  </alias>
</fontconfig>
EOF

info "[4/10] Set fcitx5 as the input method framework"
set_input_method_framework

info "[5/10] Write GNOME Wayland-friendly Fcitx session environment"
mkdir -p "$HOME/.config/environment.d" "$HOME/.config/gtk-3.0" "$HOME/.config/gtk-4.0"

cat > "$HOME/.config/environment.d/fcitx5.conf" <<'EOF'
XMODIFIERS=@im=fcitx
QT_IM_MODULE=fcitx
EOF

set_gtk_im_module_in_ini() {
  local file="$1"
  local value="$2"
  if [[ -f "$file" ]]; then
    if grep -q '^gtk-im-module=' "$file" 2>/dev/null; then
      sed -i 's/^gtk-im-module=.*/gtk-im-module='"$value"'/' "$file"
    elif grep -q '^\[Settings\]' "$file" 2>/dev/null; then
      sed -i '/^\[Settings\]/a gtk-im-module='"$value" "$file"
    else
      printf '\n[Settings]\ngtk-im-module=%s\n' "$value" >> "$file"
    fi
  else
    cat > "$file" <<EOF
[Settings]
gtk-im-module=$value
EOF
  fi
}

set_gtk_im_module_in_ini "$HOME/.config/gtk-3.0/settings.ini" "fcitx"
set_gtk_im_module_in_ini "$HOME/.config/gtk-4.0/settings.ini" "fcitx"

if [[ -f "$HOME/.gtkrc-2.0" ]]; then
  if grep -q '^gtk-im-module=' "$HOME/.gtkrc-2.0" 2>/dev/null; then
    sed -i 's/^gtk-im-module=.*/gtk-im-module="fcitx"/' "$HOME/.gtkrc-2.0"
  else
    printf 'gtk-im-module="fcitx"\n' >> "$HOME/.gtkrc-2.0"
  fi
else
  cat > "$HOME/.gtkrc-2.0" <<'EOF'
gtk-im-module="fcitx"
EOF
fi

if command -v gsettings >/dev/null 2>&1 && [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
  gsettings set org.gnome.settings-daemon.plugins.xsettings overrides "{'Gtk/IMModule':<'fcitx'>}" || \
    warn "Failed to set GNOME Gtk/IMModule override; GTK config files were still written."
else
  warn "Skipped GNOME Gtk/IMModule override because gsettings or the session bus is unavailable."
fi

info "[6/10] Install rime-ice"
ensure_command git
ensure_command rsync
TMP_DIR="$(mktemp -d)"
git clone --depth=1 "$RIME_ICE_REPO" "$TMP_DIR/rime-ice"
mkdir -p "$RIME_DIR"
rsync -a --delete "$TMP_DIR/rime-ice/" "$RIME_DIR/"

info "[7/10] Set rime-ice as the default schema"
cat > "$RIME_DIR/default.custom.yaml" <<'EOF'
patch:
  schema_list:
    - schema: rime_ice
  default_schema: rime_ice
EOF

info "[8/10] Apply custom fcitx5 configurations"
FCITX5_CONF_DIR="$HOME/.config/fcitx5"
mkdir -p "$FCITX5_CONF_DIR/conf"

cat > "$FCITX5_CONF_DIR/conf/rime.conf" <<'EOF'
# Preedit Mode
PreeditMode="Composing text"
# Shared Input State
InputState=All
# Fix embedded preedit cursor at the beginning of the preedit
PreeditCursorPositionAtBeginning=False
# Action when switching input method
SwitchInputMethodBehavior="Commit commit preview"
# Deploy
Deploy=
# Synchronize
Synchronize=
EOF

cat > "$FCITX5_CONF_DIR/config" <<'EOF'
[Hotkey]
# Trigger Input Method
TriggerKeys=
# Enumerate when press trigger key repeatedly
EnumerateWithTriggerKeys=True
# Temporally switch between first and current Input Method
AltTriggerKeys=
# Enumerate Input Method Forward
EnumerateForwardKeys=
# Enumerate Input Method Backward
EnumerateBackwardKeys=
# Skip first input method while enumerating
EnumerateSkipFirst=False
# Time limit in milliseconds for triggering modifier key shortcuts
ModifierOnlyKeyTimeout=250

[Hotkey/EnumerateGroupForwardKeys]
0=Super+space

[Hotkey/EnumerateGroupBackwardKeys]
0=Shift+Super+space

[Hotkey/ActivateKeys]
0=Hangul_Hanja

[Hotkey/DeactivateKeys]
0=Hangul_Romaja

[Hotkey/PrevPage]
0=Up

[Hotkey/NextPage]
0=Down

[Hotkey/PrevCandidate]
0=Shift+Tab

[Hotkey/NextCandidate]
0=Tab

[Hotkey/TogglePreedit]
0=Control+Alt+P

[Behavior]
# Active By Default
ActiveByDefault=False
# Reset state on Focus In
resetStateWhenFocusIn=No
# Share Input State
ShareInputState=No
# Show preedit in application
PreeditEnabledByDefault=True
# Show Input Method Information when switch input method
ShowInputMethodInformation=True
# Show Input Method Information when changing focus
showInputMethodInformationWhenFocusIn=False
# Show compact input method information
CompactInputMethodInformation=True
# Show first input method information
ShowFirstInputMethodInformation=True
# Default page size
DefaultPageSize=5
# Override Xkb Option
OverrideXkbOption=False
# Custom Xkb Option
CustomXkbOption=
# Force Enabled Addons
EnabledAddons=
# Force Disabled Addons
DisabledAddons=
# Preload input method to be used by default
PreloadInputMethod=True
# Allow input method in the password field
AllowInputMethodForPassword=False
# Show preedit text when typing password
ShowPreeditForPassword=False
# Interval of saving user data in minutes
AutoSavePeriod=30
EOF

cat > "$FCITX5_CONF_DIR/profile" <<'EOF'
[Groups/0]
# Group Name
Name=Default
# Layout
Default Layout=us
# Default Input Method
DefaultIM=rime

[Groups/0/Items/0]
# Name
Name=rime
# Layout
Layout=

[GroupOrder]
0=Default
EOF

info "[9/10] Refresh font cache"
fc-cache -fv

info "[10/10] Quick checks"
fc-match -s sans-serif | grep 'CJK' | head -n 5 || true
fc-match -s serif | grep 'CJK' | head -n 5 || true
if command_exists im-config; then
  im-config -m || true
elif command_exists imsettings-switch; then
  imsettings-switch -s || true
fi

cat <<'EOF'

Next steps:
1. Log out and log back in.
2. Open "Fcitx 5 Configuration" (`fcitx5-configtool`).
3. You should see "Rime" is already in the input method list.
4. If not, add it manually in the configuration UI.
5. On GNOME Wayland, the script sets XMODIFIERS/QT_IM_MODULE globally and uses GTK config files instead of a global GTK_IM_MODULE.
6. Your custom hotkeys and cursor fixes have been applied.
7. Do not start `fcitx5` manually from SSH or a random shell; let the desktop session start it after re-login.
EOF
