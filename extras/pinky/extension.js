import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import Clutter from 'gi://Clutter';
import GLib from 'gi://GLib';
import Meta from 'gi://Meta';
import Shell from 'gi://Shell';
import St from 'gi://St';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

const PIN_KEY = 'pin-key';
const ABOVE_KEY = 'above-key';
const UNPIN_ALL_KEY = 'unpin-all-key';

export default class PinkyExtension extends Extension {
    _settings = null;
    _settingsChangedId = 0;
    // Meta.Window -> signal ids; includes windows changed through the Shell menu.
    _tracked = new Map();
    // Meta.Window -> border and optional pinned geometry/state.
    _framed = new Map();
    _createdId = 0;
    _grabId = 0;
    _monitorsId = 0;
    _virtualKeyboard = null;

    _track(win) {
        this._tracked.set(win, [
            win.connect('notify::above', () => this._syncAbove(win)),
            // Disconnect before Mutter removes the actor or changes closing geometry.
            win.connect('unmanaging', () => this._untrack(win)),
        ]);
        if (win.is_above())
            this._syncAbove(win);
    }

    _untrack(win) {
        for (const id of this._tracked.get(win))
            win.disconnect(id);
        this._tracked.delete(win);
        this._detach(win);
    }

    // Follow Mutter's above state, regardless of which UI changed it.
    _syncAbove(win) {
        const entry = this._framed.get(win);
        if (win.is_above())
            this._restyle(win, entry ?? this._attach(win));
        else if (entry?.pin)
            this._restyle(win, entry);
        else if (entry)
            this._detach(win);
    }

    _restyle(win, entry) {
        const state = entry.pin ? (win.is_above() ? 'both' : 'pin') : 'above';
        const key = `${state}-color`;
        const value = this._settings.get_string(key);
        const color = /^#[0-9a-f]{6}$/i.test(value)
            ? value : this._settings.get_default_value(key).unpack();
        const width = this._settings.get_int('border-width');
        entry.frame.style = `border: ${width}px solid ${color};`;
        entry.frame.opacity = Math.round(255 * this._settings.get_double('border-opacity'));
    }

    // Use buffer-relative coordinates; the actor can lag during animations.
    _syncFrame(win, entry) {
        const r = win.get_frame_rect();
        const b = win.get_buffer_rect();
        // Draw inside the frame so all four edges remain visible at screen edges.
        entry.frame.set_position(r.x - b.x, r.y - b.y);
        entry.frame.set_size(r.width, r.height);
    }

    _fitsSizeLimits(win, pin) {
        // Mutter lets fullscreen clients exceed size hints and ignores maximum
        // sizes when maximized. Compare client sizes, not server decorations.
        if (pin.fullscreen) return true;
        const r = win.frame_rect_to_client_rect(pin.rect);
        const [, minWidth, minHeight] = win.get_min_size();
        const [, maxWidth, maxHeight] = win.get_max_size();
        if (r.width < minWidth || r.height < minHeight) return false;
        return pin.maximized === Meta.MaximizeFlags.BOTH ||
            ((!maxWidth || r.width <= maxWidth) && (!maxHeight || r.height <= maxHeight));
    }

    _queueRestore(win, entry) {
        if (entry.restoreId) return;
        // Wayland size hints are updated after size-changed. Inspect the complete
        // commit before painting, rather than restoring against stale hints.
        entry.restoreId = global.compositor.get_laters().add(Meta.LaterType.BEFORE_REDRAW, () => {
            entry.restoreId = 0;
            this._restore(win, entry);
            return GLib.SOURCE_REMOVE;
        });
    }

    // State and geometry signals can re-enter while we restore the rectangle.
    _restore(win, entry) {
        if (entry.restoring) return;
        if (!this._fitsSizeLimits(win, entry.pin)) {
            this._unpin(win, entry);
            Main.notify('UNPINNED', `${win.title}: application size limits changed`);
            return;
        }
        entry.restoring = true;
        try {
            const {rect: r, maximized, fullscreen} = entry.pin;
            const current = win.get_maximize_flags();
            if (current & ~maximized)
                win.set_unmaximize_flags(current & ~maximized);
            if (maximized & ~current)
                win.set_maximize_flags(maximized & ~current);
            if (fullscreen && !win.is_fullscreen())
                win.make_fullscreen();
            else if (!fullscreen && win.is_fullscreen())
                win.unmake_fullscreen();
            win.move_resize_frame(false, r.x, r.y, r.width, r.height);
        } finally {
            entry.restoring = false;
        }
        this._syncFrame(win, entry);
    }

    // End Mutter's interactive move/resize rather than racing each pointer event.
    // Escape takes its native cancel path; GNOME 50 exposes no end-grab API.
    _cancelGrab(win) {
        if (!this._framed.get(win)?.pin) return;
        const time = GLib.get_monotonic_time();
        this._virtualKeyboard.notify_keyval(
            time, Clutter.KEY_Escape, Clutter.KeyState.PRESSED);
        this._virtualKeyboard.notify_keyval(
            time, Clutter.KEY_Escape, Clutter.KeyState.RELEASED);
    }

    // A child stacks and hides with its window. Use a hollow border, not a shadow.
    _attach(win) {
        const entry = {
            frame: new St.Widget({reactive: false}),
            pin: null,
            restoring: false,
            restoreId: 0,
        };
        const onGeom = () => entry.pin
            ? this._queueRestore(win, entry)
            : this._syncFrame(win, entry);
        entry.ids = [
            win.connect('position-changed', onGeom),
            win.connect('size-changed', onGeom),
        ];
        win.get_compositor_private().add_child(entry.frame);
        this._framed.set(win, entry);
        this._syncFrame(win, entry);
        return entry;
    }

    _detach(win) {
        const entry = this._framed.get(win);
        if (!entry) return;
        this._releasePin(win, entry);
        for (const id of entry.ids)
            win.disconnect(id);
        entry.frame.destroy();
        this._framed.delete(win);
    }

    _pin(win) {
        const entry = this._framed.get(win) ?? this._attach(win);
        const onState = () => this._restore(win, entry);
        const maximized = win.get_maximize_flags();
        const fullscreen = win.is_fullscreen();
        entry.pin = {
            rect: win.get_frame_rect(),
            // Side tiling uses vertical maximization, but flags do not describe
            // which side or tile partner. Pin that rectangle as a floating window.
            maximized: fullscreen || maximized === Meta.MaximizeFlags.BOTH
                ? maximized : 0,
            fullscreen,
            ids: [
                win.connect('notify::maximized-horizontally', onState),
                win.connect('notify::maximized-vertically', onState),
                win.connect('notify::fullscreen', onState),
            ],
        };
        this._restyle(win, entry);
        this._restore(win, entry);
        return entry.pin !== null;
    }

    _releasePin(win, entry) {
        if (entry.restoreId) {
            global.compositor.get_laters().remove(entry.restoreId);
            entry.restoreId = 0;
        }
        for (const id of entry.pin?.ids ?? [])
            win.disconnect(id);
        entry.pin = null;
    }

    _unpin(win, entry) {
        this._releasePin(win, entry);
        if (win.is_above()) {
            this._restyle(win, entry);
            this._syncFrame(win, entry);
        } else {
            this._detach(win);
        }
    }

    _togglePin(win) {
        const entry = this._framed.get(win);
        if (entry?.pin) {
            this._unpin(win, entry);
            Main.notify('UNPINNED', win.title);
        } else if (this._pin(win)) {
            Main.notify('PINNED 📌', win.title);
        }
    }

    _toggleAbove(win) {
        if (win.is_above()) {
            win.unmake_above();
            Main.notify('NOT ON TOP', win.title);
        } else {
            win.make_above();
            Main.notify('ALWAYS ON TOP 🔝', win.title);
        }
    }

    _unpinAll(reason = null) {
        const pinned = [...this._framed.entries()].filter(([, e]) => e.pin);
        if (pinned.length === 0) return;
        for (const [win, entry] of pinned)
            this._unpin(win, entry);
        Main.notify('UNPINNED ALL', reason ??
            `${pinned.length} window${pinned.length > 1 ? 's' : ''}`);
    }

    enable() {
        this._settings = this.getSettings();
        this._settingsChangedId = this._settings.connect('changed', () => {
            for (const [win, entry] of this._framed)
                this._restyle(win, entry);
        });
        Main.wm.addKeybinding(
            PIN_KEY, this._settings,
            Meta.KeyBindingFlags.IGNORE_AUTOREPEAT, Shell.ActionMode.NORMAL,
            () => {
                const win = global.display.focus_window;
                if (win)
                    this._togglePin(win);
            });
        Main.wm.addKeybinding(
            ABOVE_KEY, this._settings,
            Meta.KeyBindingFlags.IGNORE_AUTOREPEAT, Shell.ActionMode.NORMAL,
            () => {
                const win = global.display.focus_window;
                if (win)
                    this._toggleAbove(win);
            });
        Main.wm.addKeybinding(
            UNPIN_ALL_KEY, this._settings,
            Meta.KeyBindingFlags.IGNORE_AUTOREPEAT, Shell.ActionMode.NORMAL,
            () => this._unpinAll());

        // Above is mutter state and survives disable/enable (the shell
        // disables extensions on screen lock), so the initial sweep restores
        // borders to windows already on top.
        this._createdId = global.display.connect('window-created',
            (_display, win) => this._track(win));
        for (const win of global.display.list_all_windows())
            this._track(win);

        const seat = global.stage.get_context().get_backend().get_default_seat();
        this._virtualKeyboard = seat.create_virtual_device(
            Clutter.InputDeviceType.KEYBOARD_DEVICE);
        this._grabId = global.display.connect('grab-op-begin',
            (_display, win) => this._cancelGrab(win));
        this._monitorsId = Main.layoutManager.connect('monitors-changed',
            () => this._unpinAll('Display layout changed'));
    }

    disable() {
        this._settings.disconnect(this._settingsChangedId);
        this._settingsChangedId = 0;
        Main.wm.removeKeybinding(PIN_KEY);
        Main.wm.removeKeybinding(ABOVE_KEY);
        Main.wm.removeKeybinding(UNPIN_ALL_KEY);
        Main.layoutManager.disconnect(this._monitorsId);
        this._monitorsId = 0;
        global.display.disconnect(this._grabId);
        this._grabId = 0;
        this._virtualKeyboard = null;
        global.display.disconnect(this._createdId);
        this._createdId = 0;
        // Pins release with their signal handlers; above state is left intact
        // deliberately — disabling (e.g. on lock) must not strip user-set
        // on-top.
        for (const win of [...this._tracked.keys()])
            this._untrack(win);
        this._settings = null;
    }
}
