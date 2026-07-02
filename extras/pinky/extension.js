import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import Gio from 'gi://Gio';
import Meta from 'gi://Meta';
import Shell from 'gi://Shell';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

const PIN_KEY = 'pin-key';
const WM_PREFS = 'org.gnome.desktop.wm.preferences';
const TITLEBAR_ACTION = 'action-double-click-titlebar';

export default class PinkyExtension extends Extension {
    _settings = null;
    // Meta.Window -> { rect, posId, sizeId, unmanagedId, restoring }
    _pinned = new Map();
    _wm = null;
    _origShouldAnimate = null;
    _wmPrefs = null;
    _origTitlebarAction = null;
    _titlebarOverridden = false;

    // summary renders as the first (bold) line, body on the next line.
    _notify(label, emoji, title) {
        const summary = emoji ? `${label} ${emoji}` : label;
        if (title)
            Main.notify(summary, title);
        else
            Main.notify(summary);
    }

    _snapshot(win) {
        const r = win.get_frame_rect();
        return {x: r.x, y: r.y, w: r.width, h: r.height};
    }

    // Restore the pinned geometry synchronously, inside the position/size-changed
    // signal. On Wayland window geometry is client-driven and asynchronous, so
    // this cannot prevent a maximize frame from being painted (the configure we
    // issue here takes effect only after the client acks). It is kept as a
    // fallback so the window returns to its pinned rect after any maximize that
    // reaches mutter through a path other than titlebar double-click (e.g. the
    // maximize keybinding or headerbar button). The restoring guard breaks the
    // recursion that move_resize_frame would otherwise retrigger.
    _restore(win, entry) {
        if (entry.restoring) return;
        entry.restoring = true;
        try {
            const max = win.get_maximize_flags();
            if (max !== 0)
                win.unmaximize(max);
            if (win.is_fullscreen())
                win.unmake_fullscreen();
            win.move_resize_frame(false,
                entry.rect.x, entry.rect.y, entry.rect.w, entry.rect.h);
        } catch (e) {
            logError(e);
        } finally {
            entry.restoring = false;
        }
    }

    _detach(win) {
        const entry = this._pinned.get(win);
        if (!entry) return;
        try { win.disconnect(entry.unmanagedId); } catch (e) {}
        try { win.disconnect(entry.posId); } catch (e) {}
        try { win.disconnect(entry.sizeId); } catch (e) {}
        this._pinned.delete(win);
    }

    _overrideTitlebarAction() {
        if (this._titlebarOverridden) return;
        this._origTitlebarAction = this._wmPrefs.get_string(TITLEBAR_ACTION);
        this._wmPrefs.set_string(TITLEBAR_ACTION, 'none');
        this._titlebarOverridden = true;
    }

    _restoreTitlebarAction() {
        if (!this._titlebarOverridden) return;
        this._wmPrefs.set_string(TITLEBAR_ACTION, this._origTitlebarAction);
        this._titlebarOverridden = false;
    }

    _pin(win) {
        if (this._pinned.has(win)) return;
        const rect = this._snapshot(win);
        const posId = win.connect('position-changed', () => {
            const e = this._pinned.get(win);
            if (e) this._restore(win, e);
        });
        const sizeId = win.connect('size-changed', () => {
            const e = this._pinned.get(win);
            if (e) this._restore(win, e);
        });
        const unmanagedId = win.connect('unmanaged',
            () => this._detach(win));
        this._pinned.set(win, {rect, posId, sizeId, unmanagedId, restoring: false});
        // First pin: stop GTK/mutter from acting on a titlebar double-click at
        // the source. On Wayland, window geometry changes are asynchronous
        // (client-driven via xdg_toplevel configure), so once a maximize request
        // reaches mutter the maximized frame is inevitably painted before any
        // restore can take effect. Disabling the double-click action prevents
        // the request from being issued at all, so no flash. Restored when the
        // last window is unpinned.
        if (this._pinned.size === 1)
            this._overrideTitlebarAction();
        this._notify('PINNED', '📌', win.title);
    }

    _unpin(win) {
        if (!this._pinned.has(win)) return;
        this._detach(win);
        if (this._pinned.size === 0)
            this._restoreTitlebarAction();
        this._notify('UNPINNED', null, win.title);
    }

    _toggle() {
        const win = global.display.focus_window;
        if (!win) return;
        if (this._pinned.has(win))
            this._unpin(win);
        else
            this._pin(win);
    }

    enable() {
        this._settings = this.getSettings();
        Main.wm.addKeybinding(
            PIN_KEY, this._settings,
            Meta.KeyBindingFlags.NONE, Shell.ActionMode.NORMAL,
            () => this._toggle()
        );

        this._wm = Main.wm;
        this._wmPrefs = new Gio.Settings({schema_id: WM_PREFS});

        // Suppress GNOME Shell's crossfade for any size change that does reach a
        // pinned window (see _restore comment). The size/minimize/map/destroy
        // handlers were bound at shell startup as this._sizeChangeWindow.bind(this),
        // so replacing that method name has no effect; but the bound body looks up
        // this._shouldAnimateActor dynamically on every call, so an instance-level
        // override is seen. For a pinned window, return false.
        this._origShouldAnimate = this._wm._shouldAnimateActor;
        const self = this;
        this._wm._shouldAnimateActor = function(actor, types) {
            if (actor && actor.meta_window && self._pinned.has(actor.meta_window))
                return false;
            return self._origShouldAnimate.apply(self._wm, arguments);
        };
    }

    disable() {
        Main.wm.removeKeybinding(PIN_KEY);
        if (this._origShouldAnimate) {
            this._wm._shouldAnimateActor = this._origShouldAnimate;
            this._origShouldAnimate = null;
        }
        this._restoreTitlebarAction();
        for (const [win] of this._pinned) this._detach(win);
        this._pinned.clear();
        this._wm = null;
        this._wmPrefs = null;
        this._settings = null;
    }
}
