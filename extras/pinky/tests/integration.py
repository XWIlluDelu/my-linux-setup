# SPDX-License-Identifier: GPL-3.0-or-later
"""Behavior checks against real GTK windows, Mutter input and rendered pixels."""
import json
import os
import time
from pathlib import Path

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("GdkPixbuf", "2.0")
from gi.repository import GdkPixbuf, Gio, GLib

BUS = Gio.bus_get_sync(Gio.BusType.SESSION, None)
UUID = "pinky@xwilludelu.github.io"
RED, BLUE, PURPLE, GREEN = "red", "blue", "purple", "green"
SUPER, SHIFT, P, T, U, LEFT, RIGHT, UP = 125, 42, 25, 20, 22, 105, 106, 103


def pump(seconds=0.1):
    until = time.monotonic() + seconds
    while time.monotonic() < until:
        while GLib.MainContext.default().iteration(False):
            pass
        time.sleep(0.005)


def call(interface, method, args=None, dest="org.gnome.Shell", path="/org/gnome/Shell"):
    return BUS.call_sync(dest, path, interface, method, args, None,
                         Gio.DBusCallFlags.NO_AUTO_START, 5000, None).unpack()


def js(code):
    code = "const {Clutter, GLib} = imports.gi;\n" + code
    ok, result = call("org.gnome.Shell", "Eval", GLib.Variant("(s)", (code,)))
    assert ok, result
    return json.loads(result) if result else None


def wait_for(predicate, message, timeout=5):
    until = time.monotonic() + timeout
    while time.monotonic() < until:
        if predicate():
            return
        pump(0.05)
    raise AssertionError(message)


def ready():
    try:
        return UUID in call("org.gnome.Shell.Extensions", "ListExtensions")[0]
    except GLib.Error as error:
        if any(error.matches(Gio.dbus_error_quark(), code) for code in
               (Gio.DBusError.SERVICE_UNKNOWN, Gio.DBusError.NAME_HAS_NO_OWNER,
                Gio.DBusError.UNKNOWN_METHOD)):
            return False
        raise


def extension(method):
    result = call("org.gnome.Shell.Extensions", method, GLib.Variant("(s)", (UUID,)))
    if method == "EnableExtension":
        wait_for(lambda: extension("GetExtensionInfo")[0].get("state") == 1, "extension enable")
    return result


def rect():
    return js("(()=>{const r=global.testWin.get_frame_rect();return [r.x,r.y,r.width,r.height]})()")


def key_event(code, state):
    js(f"global.testKeyboard.notify_key(GLib.get_monotonic_time(),"
       f"{code},Clutter.KeyState.{state});true")


def key(keys, hold=0.08):
    for code in keys:
        key_event(code, "PRESSED")
    pump(hold)
    for code in reversed(keys):
        key_event(code, "RELEASED")
    pump(0.4)


def window(title="Pinky behavior test"):
    w = Gtk.Window(title=title, default_width=500, default_height=300)
    w.set_child(Gtk.Label(label="Window content"))
    w.present()
    pump(0.5)
    js(f"global.testWin=global.display.list_all_windows().find(w=>w.title==={json.dumps(title)});true")
    js("global.testMain.activateWindow(global.testWin);true")
    wait_for(lambda: js("global.display.focus_window===global.testWin"), "window focus")
    return w


def edge_pixels(inset=0):
    pump(0.3)
    filename = str(Path(os.environ["XDG_RUNTIME_DIR"]) / "border.png")
    result = call("org.gnome.Shell.Screenshot", "Screenshot",
                  GLib.Variant("(bbs)", (False, False, filename)),
                  dest="org.gnome.Shell.Screenshot", path="/org/gnome/Shell/Screenshot")
    assert result[0], ("screenshot failed", result)
    pix = GdkPixbuf.Pixbuf.new_from_file(result[1])
    data, stride, channels = pix.get_pixels(), pix.get_rowstride(), pix.get_n_channels()
    x, y, width, height = rect()
    # Logical layouts express window geometry in stage units; screenshots use pixels.
    scale = pix.get_width() / js("global.stage.width")
    mid_x, mid_y = round((x + width / 2) * scale), round((y + height / 2) * scale)
    points = [(round((x + inset) * scale), mid_y),
              (round((x + width - inset) * scale) - 1, mid_y),
              (mid_x, round((y + inset) * scale)),
              (mid_x, round((y + height - inset) * scale) - 1)]
    return [tuple(data[py * stride + px * channels:py * stride + px * channels + 3])
            for px, py in points]


def border(color, inset=0):
    actual = edge_pixels(inset)
    # Check visible hue rather than CSS bytes: transparency blends with the
    # client, and the panel casts a shadow on maximized windows.
    matches = {
        RED: lambda r, g, b: r > max(g, b) + 15,
        BLUE: lambda r, g, b: b > g + 15 and g > r + 10,
        PURPLE: lambda r, g, b: b > r + 15 and r > g + 10,
        GREEN: lambda r, g, b: g > max(r, b) + 15,
    }
    assert all(matches[color](*rgb) for rgb in actual), ("visible border", color, actual, rect())
    return actual


def same_rect(expected, message):
    wait_for(lambda: rect() == expected, f"{message}: {expected} != {rect()}")
    pump(0.3)
    assert rect() == expected, message


def close(w):
    w.destroy()
    pump(0.3)
    assert js("!global.display.list_all_windows().includes(global.testWin)"), "window still managed"


def test_toggles_and_borders():
    w = window()
    # Observe notices as well as final state: an odd number of toggles can
    # produce the right final color while still repeatedly unpinning.
    js("""
        global.pinNotices = 0;
        global.noticeSignals = [];
        global.trayId = global.testMain.messageTray.connect("source-added", (_tray, source) => {
            const id = source.connect("notification-added", (_source, notice) => {
                if (notice.title === "PINNED 📌" || notice.title === "UNPINNED")
                    global.pinNotices++;
            });
            global.noticeSignals.push([source, id]);
        });
        true
    """)
    key([SUPER, SHIFT, P], 1.8)
    assert js("global.pinNotices===1"), "pin long press must toggle once"
    js("""
        global.testMain.messageTray.disconnect(global.trayId);
        global.noticeSignals.forEach(([source, id]) => source.disconnect(id));
        true
    """)
    border(RED)
    key([SUPER, SHIFT, P])
    before = rect()
    js("global.testWin.move_frame(false,200,180);true")
    wait_for(lambda: rect() != before, "pin toggle did not release after a long press")
    js('global.aboveChanges=0;global.aboveId=global.testWin.connect("notify::above",()=>global.aboveChanges++);true')
    key([SUPER, SHIFT, T], 1.8)
    assert js("global.testWin.is_above() && global.aboveChanges===1"), "above long press must toggle once"
    js("global.testWin.disconnect(global.aboveId);true")
    border(BLUE)
    key([SUPER, SHIFT, P])
    border(PURPLE)
    key([SUPER, SHIFT, U])
    border(BLUE)
    js("global.testWin.unmake_above();true")
    floating = rect()
    js("global.testWin.maximize();true")
    pump(0.6)
    before = rect()
    key([SUPER, SHIFT, P])
    border(RED)
    js("global.testWin.unmaximize();true")
    same_rect(before, "pinned maximized window")
    assert js("global.testWin.is_maximized()"), "pin must preserve maximized state"
    key([SUPER, SHIFT, U])
    js("global.testWin.unmaximize();true")
    same_rect(floating, "unmaximizing after unpin restores the floating rectangle")
    close(w)
    print("PASS: held shortcuts, independent controls and visible borders", flush=True)


def test_border_settings():
    w = window()
    key([SUPER, SHIFT, P])
    before = rect()
    js("""
        const {Gio} = imports.gi;
        const source = Gio.SettingsSchemaSource.new_from_directory(
            GLib.build_filenamev([GLib.get_user_data_dir(), "gnome-shell", "extensions",
                                  "pinky@xwilludelu.github.io", "schemas"]),
            Gio.SettingsSchemaSource.get_default(), false);
        global.borderSettings = new Gio.Settings({
            settings_schema: source.lookup("org.gnome.shell.extensions.pinky", false),
        });
        global.borderSettings.set_double("border-opacity", 1.0);
        true
    """)
    opaque = border(RED)
    js('global.borderSettings.set_double("border-opacity", 0.0);true')
    hidden = edge_pixels()
    js("global.testWin.move_frame(false,200,180);true")
    same_rect(before, "hiding a border must not unpin its window")
    js('global.borderSettings.set_double("border-opacity", 0.5);true')
    faint = border(RED)
    for full, half, background in zip(opaque, faint, hidden):
        full_contrast = sum(abs(a - b) for a, b in zip(full, background))
        half_contrast = sum(abs(a - b) for a, b in zip(half, background))
        assert 10 < half_contrast < full_contrast, ("opacity must soften the border", full, half, background)
    js('global.borderSettings.set_string("pin-color", "not-a-color");true')
    border(RED)  # A malformed setting retains the default state indicator.
    js("""
        global.borderSettings.set_int("border-width", 3);
        global.borderSettings.set_string("pin-color", "#44cc88");
        global.borderSettings.set_string("above-color", "#ef4444");
        global.borderSettings.set_string("both-color", "#3b82f6");
        true
    """)
    border(GREEN, inset=2)  # A third row/column is now visibly part of the border.
    key([SUPER, SHIFT, T])
    border(BLUE, inset=2)
    key([SUPER, SHIFT, U])
    border(RED, inset=2)
    js("""
        for (const key of ["border-width", "border-opacity", "pin-color", "above-color", "both-color"])
            global.borderSettings.reset(key);
        true
    """)
    border(BLUE)
    close(w)
    print("PASS: live width, opacity and per-state colors without changing window behavior", flush=True)


def test_geometry():
    w = window()
    key([SUPER, LEFT])
    tiled = rect()
    key([SUPER, SHIFT, P])
    same_rect(tiled, "pinning a tile preserves its visible rectangle")
    for keys in ([SUPER, RIGHT], [SUPER, LEFT], [SUPER, UP]):
        key(keys)
        same_rect(tiled, "native layout shortcut bypassed pin")
    border(RED)
    key([SUPER, SHIFT, U])
    key([SUPER, RIGHT])
    assert rect() != tiled, "native tiling must work after unpin"
    js("global.testWin.unmaximize();true")
    pump(0.5)
    key([SUPER, SHIFT, P])
    before = rect()
    js("global.testWin.move_resize_frame(false,100,150,600,350);true")
    same_rect(before, "direct move/resize")
    # Exercise Mutter's grab cancellation through its actual keyboard bindings.
    js('global.grabCount=0;global.grabId=global.display.connect("grab-op-begin",()=>global.grabCount++);true')
    for keys in ([56, 65], [56, 66]):  # Alt+F7 / Alt+F8: native keyboard move/resize
        key(keys)
        wait_for(lambda: js("!global.display.is_grabbed()"), "cancel keyboard move/resize")
        same_rect(before, "keyboard move/resize")
    x, y, _, _ = before
    for button in (1, 2):  # Super+left/middle drag: native move/resize
        js(f"global.testPointer.notify_absolute_motion(GLib.get_monotonic_time(),{x+100},{y+100});true")
        pump()
        key_event(SUPER, "PRESSED")
        pump()
        js(f"global.testPointer.notify_button(GLib.get_monotonic_time(),{button},Clutter.ButtonState.PRESSED);true")
        pump()
        js(f"global.testPointer.notify_absolute_motion(GLib.get_monotonic_time(),{x+180},{y+140});true")
        pump()
        js(f"global.testPointer.notify_button(GLib.get_monotonic_time(),{button},Clutter.ButtonState.RELEASED);true")
        key_event(SUPER, "RELEASED")
        pump(0.3)
        same_rect(before, "pointer move/resize")
    assert js("global.grabCount===4"), "all keyboard and pointer grab paths must actually run"
    js("global.display.disconnect(global.grabId);true")
    close(w)
    print("PASS: tiled/floating geometry, layout keys and native grabs", flush=True)


def test_constraints_and_lifecycle():
    w = window()
    js("global.testWin.move_frame(false,100,150);true")
    pump()
    key([SUPER, SHIFT, T])
    key([SUPER, SHIFT, P])
    w.get_child().set_size_request(900, 600)
    pump(0.7)
    assert rect()[2] >= 900, "client minimum size must win"
    border(BLUE)  # Automatic unpin leaves above intact.
    key([SUPER, SHIFT, P])
    border(PURPLE)  # The new, feasible size can be pinned again.
    w.get_child().set_size_request(-1, -1)
    w.set_resizable(False)
    w.set_default_size(360, 240)
    pump(0.6)
    assert rect()[2] < 900, "client maximum size must win"
    border(BLUE)
    key([SUPER, SHIFT, P])
    extension("DisableExtension")
    assert js("global.testWin.is_above()"), "disable must preserve Mutter's above state"
    assert extension("EnableExtension") == (True,)
    border(BLUE)
    key([SUPER, SHIFT, P])
    close(w)
    print("PASS: size limits, disable/enable and closing a pinned window", flush=True)


def test_fullscreen_transitions():
    for maximized in (False, True):
        w = window()
        js("global.testWin.move_frame(false,150,160);true")
        pump(0.3)
        floating = rect()
        if maximized:
            js("global.testWin.maximize();true")
            pump(0.5)
        before = rect()
        key([SUPER, SHIFT, T])
        key([SUPER, SHIFT, P])
        w.fullscreen()
        wait_for(lambda: js("global.testWin.is_fullscreen()"), "enter fullscreen")
        border(BLUE)  # Entering fullscreen releases pin, preserving above.
        key([SUPER, SHIFT, P])
        border(PURPLE)
        w.unfullscreen()
        same_rect(before, "leaving fullscreen preserves the original restore rectangle")
        assert js("!global.testWin.is_fullscreen()"), "fullscreen exit must complete"
        assert js("global.testWin.is_maximized()") == maximized, "restore pre-fullscreen state"
        border(BLUE)
        if maximized:
            js("global.testWin.unmaximize();true")
            same_rect(floating, "fullscreen must also preserve the floating restore rectangle")
        close(w)
    print("PASS: fullscreen transitions release pins and preserve restore geometry and above", flush=True)


def test_monitor_change():
    w = window()
    js("global.testWin.move_to_monitor(1);true")
    pump(0.5)
    key([SUPER, SHIFT, T])
    key([SUPER, SHIFT, P])
    iface = "org.gnome.Mutter.DisplayConfig"
    path = "/org/gnome/Mutter/DisplayConfig"
    serial, monitors, _, _ = call(iface, "GetCurrentState", dest=iface, path=path)
    connector = monitors[0][0][0]
    mode = monitors[0][1][0][0]
    call(iface, "ApplyMonitorsConfig", GLib.Variant("(uua(iiduba(ssa{sv}))a{sv})",
         (serial, 1, [(0, 0, 1.0, 0, True, [(connector, mode, {})])], {})), dest=iface, path=path)
    pump(0.8)
    border(BLUE)
    before = rect()
    js("global.testWin.move_frame(false,100,150);true")
    wait_for(lambda: rect() != before, "layout change must release pin")
    close(w)
    print("PASS: monitor removal releases pins, preserves above and usable placement", flush=True)

    # Physical layouts scale window actors as well as the desktop theme. The
    # border must stay on the window edges and keep its intended CSS thickness.
    serial, _, _, _ = call(iface, "GetCurrentState", dest=iface, path=path)
    call(iface, "ApplyMonitorsConfig", GLib.Variant("(uua(iiduba(ssa{sv}))a{sv})",
         (serial, 1, [(0, 0, 2.0, 0, True, [(connector, mode, {})])],
          {"layout-mode": GLib.Variant("u", 2)})), dest=iface, path=path)
    pump(0.8)
    w = window()
    js("global.testWin.move_frame(false,200,180);true")
    key([SUPER, SHIFT, T])
    border(BLUE)
    border(BLUE, inset=1)
    assert all(not (b > g + 15 and g > r + 10) for r, g, b in edge_pixels(2)), \
        "a 1px border at 200% must end after two physical pixels"
    close(w)
    print("PASS: border placement and thickness at 200% physical scaling", flush=True)

    serial, _, _, _ = call(iface, "GetCurrentState", dest=iface, path=path)
    call(iface, "ApplyMonitorsConfig", GLib.Variant("(uua(iiduba(ssa{sv}))a{sv})",
         (serial, 1, [(0, 0, 1.5, 0, True, [(connector, mode, {})])],
          {"layout-mode": GLib.Variant("u", 1)})), dest=iface, path=path)
    pump(0.8)
    w = window()
    js("global.testWin.move_frame(false,200,180);true")
    key([SUPER, SHIFT, P])
    before = rect()
    js("global.testWin.move_resize_frame(false,100,150,600,350);true")
    same_rect(before, "pin retains logical geometry at 150%")
    border(RED)
    close(w)
    print("PASS: pinned geometry and visible borders at 150% logical scaling", flush=True)


def test_workarea_change():
    w = window("Pinky affected work area")
    js("global.testWin.move_frame(false,100,100);global.workareaWin=global.testWin;true")
    key([SUPER, SHIFT, T])
    key([SUPER, SHIFT, P])
    other = window("Pinky unaffected work area")
    js("global.testWin.move_to_monitor(1);true")
    pump(0.5)
    key([SUPER, SHIFT, T])
    key([SUPER, SHIFT, P])
    js("""
        global.testDock = new imports.gi.St.Widget({x: 0, y: 0, width: 1280, height: 180});
        global.testMain.layoutManager.addChrome(global.testDock, {affectsStruts: true});
        true
    """)
    pump(0.5)
    border(PURPLE)  # A change on the other monitor must not release this pin.
    before = rect()
    js("global.testWin.move_frame(false,1400,200);true")
    same_rect(before, "unaffected work area retains its pin")
    close(other)
    js("global.testWin=global.workareaWin;true")
    border(BLUE)
    before = rect()
    js("global.testWin.move_frame(false,200,220);true")
    wait_for(lambda: rect() != before, "changed work area must release pin")
    js("global.testMain.layoutManager.removeChrome(global.testDock);global.testDock.destroy();true")
    close(w)
    print("PASS: work area changes release only affected pins and preserve above", flush=True)


if __name__ == "__main__":
    wait_for(ready, "GNOME startup and extension discovery", timeout=20)
    assert extension("EnableExtension") == (True,)
    js("""
        const seat = global.stage.get_context().get_backend().get_default_seat();
        global.testKeyboard = seat.create_virtual_device(Clutter.InputDeviceType.KEYBOARD_DEVICE);
        global.testPointer = seat.create_virtual_device(Clutter.InputDeviceType.POINTER_DEVICE);
        global.testPointer.notify_absolute_motion(GLib.get_monotonic_time(), 600, 400);
        true
    """)
    pump(0.2)  # Initial pointer creation can enter the hot corner at (0, 0).
    js("global.testMain.overview.hide();true")
    wait_for(lambda: js("!global.testMain.overview.visible && "
                        "global.testMain.actionMode===imports.gi.Shell.ActionMode.NORMAL"),
             "normal desktop input mode")
    from gi.repository import Gtk
    Gtk.init()
    js("""
        new imports.gi.Gio.Settings({schema_id: "org.gnome.desktop.notifications"})
            .set_boolean("show-banners", false);
        global.testMain.messageTray.getSources().forEach(source => source.destroy());
        true
    """)
    test_toggles_and_borders()
    test_border_settings()
    test_geometry()
    test_constraints_and_lifecycle()
    test_fullscreen_transitions()
    test_workarea_change()
    test_monitor_change()
