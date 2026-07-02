import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import Gio from 'gi://Gio';
import Meta from 'gi://Meta';
import Shell from 'gi://Shell';
import St from 'gi://St';
import {Extension, InjectionManager} from 'resource:///org/gnome/shell/extensions/extension.js';

const PIN_KEY = 'pin-key';
const UNPIN_ALL_KEY = 'unpin-all-key';
const BORDER = 2;

// org.gnome.desktop.interface::accent-color is an enum with no color values
// attached; these are the RGB values GNOME itself renders for each entry.
const ACCENT_RGB = {
    blue:   [53, 132, 228],
    teal:   [26, 162, 178],
    green:  [38, 162, 105],
    yellow: [226, 167, 11],
    orange: [196, 92, 22],
    red:    [224, 27, 36],
    pink:   [222, 72, 161],
    purple: [151, 77, 255],
    slate:  [98, 106, 127],
};

export default class PinkyExtension extends Extension {
    _settings = null;
    // Meta.Window -> {rect, winIds, actor, frame, restoring}
    _pinned = new Map();
    _injectionManager = null;
    _ifacePrefs = null;
    _accentId = 0;
    _accentCss = '';

    _loadAccent() {
        const rgb = ACCENT_RGB[this._ifacePrefs.get_string('accent-color')] ?? ACCENT_RGB.blue;
        this._accentCss = `border: ${BORDER}px solid rgb(${rgb.join(',')});`;
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
            win.move_resize_frame(false,
                entry.rect.x, entry.rect.y, entry.rect.w, entry.rect.h);
        } finally {
            entry.restoring = false;
        }
        this._syncFrame(entry);
    }

    // Child coordinates are relative to the actor origin, which is the buffer
    // rect (frame rect plus the client shadow margin), not the frame rect.
    _syncFrame(entry) {
        const {rect, actor, frame} = entry;
        frame.set_position(rect.x - actor.x - BORDER, rect.y - actor.y - BORDER);
        frame.set_size(rect.w + 2 * BORDER, rect.h + 2 * BORDER);
    }

    _detach(win) {
        const entry = this._pinned.get(win);
        if (!entry) return;
        for (const id of entry.winIds)
            win.disconnect(id);
        entry.frame.destroy();
        this._pinned.delete(win);
    }

    _pin(win) {
        const r = win.get_frame_rect();
        // Pin indicator: a hollow 2px accent-colored ring just outside the
        // frame rect. It is a child of the window actor so it stacks, hides,
        // and dies with the window; a sibling in window_group gets thrown
        // above other windows whenever mutter restacks, because mutter
        // restacks only the MetaWindowActors. Border only — St renders
        // box-shadow on large actors by 9-slice stretching a small blurred
        // texture, which fills a hollow interior with a translucent tint.
        const entry = {
            rect: {x: r.x, y: r.y, w: r.width, h: r.height},
            actor: win.get_compositor_private(),
            frame: new St.Widget({style: this._accentCss, reactive: false}),
            restoring: false,
        };
        const onGeom = () => this._restore(win, entry);
        entry.winIds = [
            win.connect('position-changed', onGeom),
            win.connect('size-changed', onGeom),
            win.connect('notify::maximized-horizontally', onGeom),
            win.connect('notify::maximized-vertically', onGeom),
            win.connect('notify::fullscreen', onGeom),
            win.connect('unmanaged', () => this._detach(win)),
        ];
        entry.actor.add_child(entry.frame);
        this._pinned.set(win, entry);
        this._syncFrame(entry);
        Main.notify('PINNED 📌', win.title);
    }

    _toggle() {
        const win = global.display.focus_window;
        if (!win) return;
        if (this._pinned.has(win)) {
            this._detach(win);
            Main.notify('UNPINNED', win.title);
        } else {
            this._pin(win);
        }
    }

    _unpinAll() {
        const count = this._pinned.size;
        if (count === 0) return;
        for (const win of [...this._pinned.keys()])
            this._detach(win);
        Main.notify('UNPINNED ALL', `${count} window${count > 1 ? 's' : ''}`);
    }

    enable() {
        this._settings = this.getSettings();
        Main.wm.addKeybinding(
            PIN_KEY, this._settings,
            Meta.KeyBindingFlags.NONE, Shell.ActionMode.NORMAL,
            () => this._toggle());
        Main.wm.addKeybinding(
            UNPIN_ALL_KEY, this._settings,
            Meta.KeyBindingFlags.NONE, Shell.ActionMode.NORMAL,
            () => this._unpinAll());

        // Accent color follows the desktop setting and updates live.
        this._ifacePrefs = new Gio.Settings({schema_id: 'org.gnome.desktop.interface'});
        this._loadAccent();
        this._accentId = this._ifacePrefs.connect('changed::accent-color', () => {
            this._loadAccent();
            for (const entry of this._pinned.values())
                entry.frame.style = this._accentCss;
        });

        // Suppress GNOME Shell's crossfade for any size change that reaches a
        // pinned window through a path the notify:: signals don't catch early
        // enough. InjectionManager stacks correctly with other extensions
        // overriding the same method and restores cleanly on disable.
        this._injectionManager = new InjectionManager();
        const pinned = this._pinned;
        this._injectionManager.overrideMethod(
            Object.getPrototypeOf(Main.wm), '_shouldAnimateActor',
            originalMethod => function (actor, types) {
                if (actor?.meta_window && pinned.has(actor.meta_window))
                    return false;
                return originalMethod.call(this, actor, types);
            });
    }

    disable() {
        Main.wm.removeKeybinding(PIN_KEY);
        Main.wm.removeKeybinding(UNPIN_ALL_KEY);
        this._injectionManager.clear();
        this._injectionManager = null;
        this._ifacePrefs.disconnect(this._accentId);
        this._accentId = 0;
        this._ifacePrefs = null;
        for (const win of [...this._pinned.keys()])
            this._detach(win);
        this._settings = null;
    }
}
