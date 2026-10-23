#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Opt-in integration test: all runtime changes stay in a disposable GNOME session.
set -Eeuo pipefail
if (($# > 1)); then
    echo "Usage: $0 [EXTENSION_BUNDLE]" >&2
    exit 2
fi
root="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/pinky-tests.XXXXXX")"
trap 'rm -r -- "$test_dir"' EXIT
if (($#)); then
    bundle="$(realpath -- "$1")"
else
    gnome-extensions pack --extra-source=LICENSE --out-dir="$test_dir" "$root"
    bundle="$test_dir/pinky@xwilludelu.github.io.shell-extension.zip"
fi

# Keep the test home, settings, caches and Wayland socket separate from the desktop.
mkdir -p "$test_dir"/{home,config,cache,runtime}
chmod 700 "$test_dir/runtime"

# No service activation: exercise Shell without starting portal/automount daemons.
cat > "$test_dir/bus.conf" <<'DBUS'
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

env -u DISPLAY -u WAYLAND_DISPLAY \
    HOME="$test_dir/home" XDG_DATA_HOME="$test_dir/data" XDG_CONFIG_HOME="$test_dir/config" \
    XDG_CACHE_HOME="$test_dir/cache" XDG_STATE_HOME="$test_dir/state" XDG_RUNTIME_DIR="$test_dir/runtime" \
    GSETTINGS_BACKEND=memory LIBGL_ALWAYS_SOFTWARE=1 GTK_A11Y=none GDK_BACKEND=wayland \
    dbus-run-session --config-file="$test_dir/bus.conf" -- bash -eu -s -- "$root" "$test_dir" "$bundle" <<'SESSION'
root="$1"
tmp="$2"
gnome-extensions install "$3"
# Shell's automation entry point enables Eval without modifying the installed ZIP.
cat > "$tmp/bootstrap.js" <<'JS'
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

export function init() {
    global.context.unsafe_mode = true;
    global.testMain = Main;
}

export function run() {
    // The Python runner owns the lifetime of this disposable Shell.
    return new Promise(() => {});
}
JS
gnome-shell --automation-script="$tmp/bootstrap.js" \
    --wayland --headless --no-x11 --force-animations \
    --virtual-monitor 1920x1200 --virtual-monitor 1280x800 \
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
if grep -F "pinky@xwilludelu.github.io/extension.js" "$tmp/shell.log"; then exit 1; fi
SESSION
