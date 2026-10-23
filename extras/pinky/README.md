# Pinky

Pinky is a GNOME Shell 50–51 / Wayland extension with two independent controls: pin a window's position and size, or keep it always on top.

## Use

| Shortcut | Action |
|---|---|
| `Super+Shift+P` | Toggle geometry pin on the focused window |
| `Super+Shift+T` | Toggle always-on-top on the focused window |
| `Super+Shift+U` | Unpin every pinned window; leave always-on-top unchanged |

Holding a shortcut acts once. A 1px inset border at 65% opacity shows the state: **red** for pinned, **blue** for always-on-top, **purple** for both. Changes through the Shell's window menu update the border too. The border follows the window's stacking and visibility, including when maximized or fullscreen.

### What pinning preserves

- **Floating windows:** keep the current frame rectangle.
- **Side-tiled or single-axis-maximized windows:** become floating at the same rectangle. Unpinning leaves them floating; it does not rebuild the previous tiling relationship.
- **Maximized and fullscreen windows:** keep their rectangle and state.

Pinky cancels interactive moves and resizes through Mutter's Escape handler and restores geometry/state after other attempts to change them. Closing, minimizing and changing workspaces remain available. Unpinning stops enforcement without moving the window.

Application size limits and display layout take precedence over a pin:

- If new minimum/maximum sizes no longer permit the saved rectangle, Pinky unpins that window and notifies you. You can pin its new size again. Size hints follow Mutter's rules: fullscreen ignores them, and maximized windows ignore maximum sizes.
- Changing display layout, resolution or scale releases all pins with a notification, so Mutter can place windows in the new layout.

Disabling the extension also releases pins, including on screen lock. Always-on-top is Mutter state and remains unchanged by all these releases.

### Adjust the border

Appearance changes apply immediately to existing borders. Configure them with GSettings; there is no preferences UI.

| Setting | Values |
|---|---|
| `border-width` | 1–8 CSS pixels; default 1 |
| `border-opacity` | 0.0–1.0; default 0.65. Zero hides borders without unpinning or changing always-on-top. |
| `pin-color`, `above-color`, `both-color` | `#rrggbb` colors for the three states |

For example, make the border fainter or use a muted orange for pinned windows:

```bash
schema="$HOME/.local/share/gnome-shell/extensions/pinky@local/schemas"
gsettings --schemadir "$schema" set org.gnome.shell.extensions.pinky border-opacity 0.45
gsettings --schemadir "$schema" set org.gnome.shell.extensions.pinky pin-color "'#d08770'"
```

Use `gsettings --schemadir "$schema" reset org.gnome.shell.extensions.pinky border-opacity` to restore the default opacity. Other appearance keys can be reset the same way.

### Change shortcuts

Set `pin-key`, `above-key` or `unpin-all-key` with GSettings, for example:

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

It starts a headless compositor on a private session bus with temporary home/config directories and in-memory settings. It does not change the installed extension or the running desktop. Real GTK4 Wayland windows, virtual keyboard/pointer input and screenshot pixels check pinning, held shortcuts, border appearance (including 200% physical scaling), size limits, display changes and disable/enable cleanup.

On your desktop, also try title-bar/edge gestures, minimizing and workspace changes with your usual apps and other extensions, especially when using fractional scaling.
