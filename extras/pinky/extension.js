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
        this._syncTitlebarAction();
    }

    // Reconcile the global titlebar double-click action with the pinned set.
    // Single source of truth: derived from _pinned.size, called after every
    // mutation (pin, unpin, unmanaged detach), so the override state can never
    // desync from the pinned set. On Wayland, window geometry is client-driven
    // and asynchronous, so once a maximize request reaches mutter the maximized
    // frame is inevitably painted before any in-signal restore can take effect
    // (see _restore); disabling the double-click at its gsetting source is the
    // only way to prevent the flash. org.gnome.desktop.wm.preferences has no
    // per-window override, so this is necessarily global: while any window is
    // pinned, double-clicking any titlebar does nothing. The captured original
    // value and an override-active flag are persisted in the extension's own
    // settings so a shell crash (which skips disable()) is self-healed on the
    // next enable() instead of leaving the desktop stuck with the action at
    // 'none'.
    _syncTitlebarAction() {
        const wantOverride = this._pinned.size > 0;
        if (wantOverride === this._titlebarOverridden)
            return;
        if (wantOverride) {
            this._settings.set_string('orig-titlebar-action',
                this._wmPrefs.get_string(TITLEBAR_ACTION));
            this._settings.set_boolean('titlebar-override-active', true);
            this._wmPrefs.set_string(TITLEBAR_ACTION, 'none');
            this._titlebarOverridden = true;
        } else {
            this._wmPrefs.set_string(TITLEBAR_ACTION,
                this._settings.get_string('orig-titlebar-action'));
            this._settings.set_boolean('titlebar-override-active', false);
            this._titlebarOverridden = false;
        }
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
        this._syncTitlebarAction();
        this._notify('PINNED', '📌', win.title);
    }

    _unpin(win) {
        if (!this._pinned.has(win)) return;
        this._detach(win);
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

        // Self-heal a crashed override. If the shell died while a window was
        // pinned, disable() never ran, the WM pref is stuck at 'none' in dconf,
        // and our override-active flag is still set. Restore the captured
        // original before accepting any new pin.
        if (this._settings.get_boolean('titlebar-override-active')) {
            this._wmPrefs.set_string(TITLEBAR_ACTION,
                this._settings.get_string('orig-titlebar-action'));
            this._settings.set_boolean('titlebar-override-active', false);
        }

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
        // _detach reconciles the titlebar action as the set drains, so the last
        // detached window restores the WM pref and clears the override flag.
        for (const [win] of this._pinned) this._detach(win);
        this._wm = null;
        this._wmPrefs = null;
        this._settings = null;
    }
}
