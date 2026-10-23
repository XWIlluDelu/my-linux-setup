# Pinky

Pinky is a GNOME Shell 50–51 / Wayland extension with two independent controls: pin a window's position and size, or keep it always on top.

## Use

| Shortcut | Action |
|---|---|
| `Super+Shift+P` | Toggle geometry pin on the focused window |
| `Super+Shift+T` | Toggle always-on-top on the focused window |
| `Super+Shift+U` | Unpin every pinned window; leave always-on-top unchanged |

Holding a shortcut acts once. A 2px inset border shows the state: **red** for pinned, **blue** for always-on-top, **purple** for both. Changes through the Shell's window menu update the border too. The border follows the window's stacking and visibility, including when maximized or fullscreen.

### What pinning preserves

- **Floating windows:** keep the current frame rectangle.
- **Side-tiled or single-axis-maximized windows:** become floating at the same rectangle. Unpinning leaves them floating; it does not rebuild the previous tiling relationship.
- **Maximized and fullscreen windows:** keep their rectangle and state.

Pinky cancels interactive moves and resizes through Mutter's Escape handler and restores geometry/state after other attempts to change them. Closing, minimizing and changing workspaces remain available. Unpinning stops enforcement without moving the window.

Application size limits and display layout take precedence over a pin:

- If new minimum/maximum sizes no longer permit the saved rectangle, Pinky unpins that window and notifies you. You can pin its new size again. Size hints follow Mutter's rules: fullscreen ignores them, and maximized windows ignore maximum sizes.
- Changing display layout, resolution or scale releases all pins with a notification, so Mutter can place windows in the new layout.

Disabling the extension also releases pins, including on screen lock. Always-on-top is Mutter state and remains unchanged by all these releases.

### Change shortcuts

There is no preferences UI. Set `pin-key`, `above-key` or `unpin-all-key` with GSettings, for example:

```bash
gsettings --schemadir ~/.local/share/gnome-shell/extensions/pinky@local/schemas \
  set org.gnome.shell.extensions.pinky pin-key "['<Super><Shift>p']"
```

## Install or update

Run from the repository root:

```bash
dest="$HOME/.local/share/gnome-shell/extensions/pinky@local"
mkdir -p "$dest/schemas"
cp extras/pinky/{extension.js,metadata.json} "$dest/"
cp extras/pinky/schemas/*.xml "$dest/schemas/"
glib-compile-schemas "$dest/schemas"
```

Log out and back in to discover a new installation or load updated code, then enable it:

```bash
gnome-extensions enable pinky@local
gnome-extensions info pinky@local
```

The extension should report `State: ACTIVE` and the version in `metadata.json`.

## Verify behavior

The opt-in integration test needs GNOME Shell 50 or 51, Python 3 with PyGObject, GTK4 and GdkPixbuf typelibs, `dbus-run-session`, and `glib-compile-schemas`:

```bash
bash extras/pinky/tests/run.sh
```

It starts a headless compositor on a private session bus with temporary home/config directories and in-memory settings. It does not change the installed extension or the running desktop. Real GTK4 Wayland windows, virtual keyboard/pointer input and screenshot pixels check pinning, held shortcuts, visible borders, size limits, display changes and disable/enable cleanup.

On your desktop, also try title-bar/edge gestures, minimizing and workspace changes with your usual apps and other extensions, especially when using fractional scaling.
