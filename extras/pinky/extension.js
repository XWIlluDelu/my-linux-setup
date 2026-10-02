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
const BORDER = 2;

const COLOR = {
    pin: '#ef4444',
    above: '#3b82f6',
    both: '#8b5cf6',
};

export default class PinkyExtension extends Extension {
    _settings = null;
    // Meta.Window -> signal ids; includes windows changed through the Shell menu.
    _tracked = new Map();
    // Meta.Window -> border and optional pinned geometry/state.
    _framed = new Map();
    _createdId = 0;
    _grabId = 0;
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
        const color = entry.pin
            ? (win.is_above() ? COLOR.both : COLOR.pin)
            : COLOR.above;
        entry.frame.style = `border: ${BORDER}px solid ${color};`;
    }

    // Use buffer-relative coordinates; the actor can lag during animations.
    _syncFrame(win, entry) {
        const r = win.get_frame_rect();
        const b = win.get_buffer_rect();
        entry.frame.set_position(r.x - b.x - BORDER, r.y - b.y - BORDER);
        entry.frame.set_size(r.width + 2 * BORDER, r.height + 2 * BORDER);
    }

    // State and geometry signals can re-enter while we restore the rectangle.
    _restore(win, entry) {
        if (entry.restoring) return;
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
        };
        const onGeom = () => entry.pin
            ? this._restore(win, entry)
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
        for (const id of [...entry.ids, ...(entry.pin?.ids ?? [])])
            win.disconnect(id);
        entry.frame.destroy();
        this._framed.delete(win);
    }

    _pin(win) {
        const entry = this._framed.get(win) ?? this._attach(win);
        const onState = () => this._restore(win, entry);
        entry.pin = {
            rect: win.get_frame_rect(),
            maximized: win.get_maximize_flags(),
            fullscreen: win.is_fullscreen(),
            ids: [
                win.connect('notify::maximized-horizontally', onState),
                win.connect('notify::maximized-vertically', onState),
                win.connect('notify::fullscreen', onState),
            ],
        };
        this._restyle(win, entry);
    }

    _unpin(win, entry) {
        for (const id of entry.pin.ids)
            win.disconnect(id);
        entry.pin = null;
        if (win.is_above())
            this._restyle(win, entry);
        else
            this._detach(win);
    }

    _togglePin(win) {
        const entry = this._framed.get(win);
        if (entry?.pin) {
            this._unpin(win, entry);
            Main.notify('UNPINNED', win.title);
        } else {
            this._pin(win);
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

    _unpinAll() {
        const pinned = [...this._framed.entries()].filter(([, e]) => e.pin);
        if (pinned.length === 0) return;
        for (const [win, entry] of pinned)
            this._unpin(win, entry);
        Main.notify('UNPINNED ALL', `${pinned.length} window${pinned.length > 1 ? 's' : ''}`);
    }

    enable() {
        this._settings = this.getSettings();
        Main.wm.addKeybinding(
            PIN_KEY, this._settings,
            Meta.KeyBindingFlags.NONE, Shell.ActionMode.NORMAL,
            () => {
                const win = global.display.focus_window;
                if (win)
                    this._togglePin(win);
            });
        Main.wm.addKeybinding(
            ABOVE_KEY, this._settings,
            Meta.KeyBindingFlags.NONE, Shell.ActionMode.NORMAL,
            () => {
                const win = global.display.focus_window;
                if (win)
                    this._toggleAbove(win);
            });
        Main.wm.addKeybinding(
            UNPIN_ALL_KEY, this._settings,
            Meta.KeyBindingFlags.NONE, Shell.ActionMode.NORMAL,
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
    }

    disable() {
        Main.wm.removeKeybinding(PIN_KEY);
        Main.wm.removeKeybinding(ABOVE_KEY);
        Main.wm.removeKeybinding(UNPIN_ALL_KEY);
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
