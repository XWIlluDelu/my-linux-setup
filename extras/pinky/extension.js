import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import Meta from 'gi://Meta';
import Shell from 'gi://Shell';
import St from 'gi://St';
import {Extension, InjectionManager} from 'resource:///org/gnome/shell/extensions/extension.js';

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
    // Every managed window, so above flips from any source (our keybinding,
    // the shell window menu) reach the reconciler. Meta.Window -> signal ids.
    _tracked = new Map();
    // Windows wearing a border: pinned, on top, or both.
    // Meta.Window -> {actor, frame, ids, restoring, pin: {rect, ids} | null}
    _framed = new Map();
    _injectionManager = null;
    _createdId = 0;

    _track(win) {
        this._tracked.set(win, [
            win.connect('notify::above', () => this._syncAbove(win)),
            win.connect('unmanaged', () => this._untrack(win)),
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

    // Single authority for the border's above component: the keybinding and
    // the window menu both just flip the mutter property, and the border
    // follows it here.
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

    // Child coordinates are relative to the actor origin, which is the buffer
    // rect (frame rect plus the client shadow margin), not the frame rect.
    _syncFrame(win, entry) {
        const {actor, frame} = entry;
        const r = entry.pin?.rect ?? win.get_frame_rect();
        frame.set_position(r.x - actor.x - BORDER, r.y - actor.y - BORDER);
        frame.set_size(r.width + 2 * BORDER, r.height + 2 * BORDER);
    }

    // Restore the pinned geometry. The notify::maximized-*/fullscreen property
    // signals fire when the state flags flip but BEFORE mutter commits the new
    // geometry, so unmaximize + move_resize_frame here cancels the transition
    // before any maximized frame is painted; position-changed/size-changed
    // catch plain move/resize grabs. The restoring guard breaks the recursion
    // those signals would otherwise retrigger through move_resize_frame.
    _restore(win, entry) {
        if (entry.restoring) return;
        entry.restoring = true;
        try {
            if (win.get_maximize_flags() !== 0)
                win.unmaximize();
            if (win.is_fullscreen())
                win.unmake_fullscreen();
            const r = entry.pin.rect;
            win.move_resize_frame(false, r.x, r.y, r.width, r.height);
        } finally {
            entry.restoring = false;
        }
        this._syncFrame(win, entry);
    }

    // Indicator: a hollow 2px ring just outside the frame rect. It is a child
    // of the window actor so it stacks, hides, and dies with the window; a
    // sibling in window_group gets thrown above other windows whenever mutter
    // restacks, because mutter restacks only the MetaWindowActors. Border
    // only — St renders box-shadow on large actors by 9-slice stretching a
    // small blurred texture, which fills a hollow interior with a translucent
    // tint.
    _attach(win) {
        const entry = {
            actor: win.get_compositor_private(),
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
        entry.actor.add_child(entry.frame);
        // Mutter may destroy the window actor — and the frame with it —
        // before 'unmanaged' reaches _detach; track that so _detach never
        // touches a disposed widget.
        entry.frame.connect('destroy', () => (entry.frame = null));
        this._framed.set(win, entry);
        this._syncFrame(win, entry);
        return entry;
    }

    _detach(win) {
        const entry = this._framed.get(win);
        if (!entry) return;
        for (const id of [...entry.ids, ...(entry.pin?.ids ?? [])])
            win.disconnect(id);
        entry.frame?.destroy();
        this._framed.delete(win);
    }

    _pin(win) {
        const entry = this._framed.get(win) ?? this._attach(win);
        const onGeom = () => this._restore(win, entry);
        entry.pin = {
            rect: win.get_frame_rect(),
            ids: [
                win.connect('notify::maximized-horizontally', onGeom),
                win.connect('notify::maximized-vertically', onGeom),
                win.connect('notify::fullscreen', onGeom),
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

        this._injectionManager = new InjectionManager();

        // Suppress GNOME Shell's crossfade for any size change that reaches a
        // pinned window through a path the notify:: signals don't catch early
        // enough. InjectionManager stacks correctly with other extensions
        // overriding the same method and restores cleanly on disable.
        const framed = this._framed;
        this._injectionManager.overrideMethod(
            Object.getPrototypeOf(Main.wm), '_shouldAnimateActor',
            originalMethod => function (actor, types) {
                if (actor?.meta_window && framed.get(actor.meta_window)?.pin)
                    return false;
                return originalMethod.call(this, actor, types);
            });
    }

    disable() {
        Main.wm.removeKeybinding(PIN_KEY);
        Main.wm.removeKeybinding(ABOVE_KEY);
        Main.wm.removeKeybinding(UNPIN_ALL_KEY);
        this._injectionManager.clear();
        this._injectionManager = null;
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
