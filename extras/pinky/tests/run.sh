#!/usr/bin/env bash
# Opt-in integration test: all runtime changes stay in a disposable GNOME session.
set -Eeuo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/pinky-tests.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT

# Keep the test home, settings, caches and Wayland socket separate from the desktop.
export HOME="$TMP/home" XDG_DATA_HOME="$TMP/data" XDG_CONFIG_HOME="$TMP/config"
export XDG_CACHE_HOME="$TMP/cache" XDG_STATE_HOME="$TMP/state" XDG_RUNTIME_DIR="$TMP/runtime"
export GSETTINGS_BACKEND=memory LIBGL_ALWAYS_SOFTWARE=1 GTK_A11Y=none GDK_BACKEND=wayland
unset DISPLAY WAYLAND_DISPLAY
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

# No service activation: exercise Shell without starting portal/automount daemons.
cat > "$TMP/bus.conf" <<'DBUS'
<busconfig>
  <type>session</type>
  <listen>unix:tmpdir=/tmp</listen>
  <policy context="default">
    <allow own="*"/>
    <allow send_destination="*"/>
    <allow receive_sender="*"/>
  </policy>
</busconfig>
DBUS

dbus-run-session --config-file="$TMP/bus.conf" -- bash -eu -s -- "$ROOT" "$TMP" <<'SESSION'
root="$1"
tmp="$2"
dest="$XDG_DATA_HOME/gnome-shell/extensions/pinky@local"
mkdir -p "$dest/schemas"
cp "$root"/{extension.js,metadata.json} "$dest/"
cp "$root"/schemas/*.xml "$dest/schemas/"
glib-compile-schemas --strict "$dest/schemas"
# Enable Eval only in the disposable copy, never in the installed extension.
python3 - "$dest/extension.js" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
p.write_text(p.read_text().replace('    enable() {', '''    enable() {
        global.context.unsafe_mode = true;
        global.testMain = Main;''', 1))
PY
gnome-shell --wayland --headless --no-x11 --force-animations \
    --virtual-monitor 2560x1600 --virtual-monitor 1280x800 \
    --wayland-display pinky-test > "$tmp/shell.log" 2>&1 &
shell=$!
cleanup() {
    local status=$?
    if ((status)); then tail -n 80 "$tmp/shell.log"; fi
    kill "$shell" 2>/dev/null || true
    wait "$shell" 2>/dev/null || true
    return "$status"
}
trap cleanup EXIT
export WAYLAND_DISPLAY=pinky-test
timeout 90s python3 "$root/tests/integration.py"
# Catch extension exceptions from asynchronous handlers as well as test failures.
if grep -F "pinky@local/extension.js" "$tmp/shell.log"; then exit 1; fi
SESSION
