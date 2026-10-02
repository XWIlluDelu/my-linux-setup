# Pinky

Pinky v7 is a GNOME Shell 50 / Wayland extension with two independent controls: pin a window's position and size, or keep it always on top.

## Use

| Shortcut | Action |
|---|---|
| `Super+Shift+P` | Toggle geometry pin on the focused window |
| `Super+Shift+T` | Toggle always-on-top on the focused window |
| `Super+Shift+U` | Unpin every pinned window; leave always-on-top unchanged |

A 2px border shows the state: **red** for pinned, **blue** for always-on-top, **purple** for both. Changes through the Shell's window menu update the border too.

Pinning saves the window's frame rectangle and maximize/fullscreen state. Pinky cancels interactive moves and resizes through Mutter's Escape handler, and restores the saved geometry and state after other changes. Closing, minimizing and workspace changes remain available.

Pins last until unpinned or the extension is disabled, including on screen lock. Always-on-top is Mutter state and survives disable/enable. The border follows the window's stacking and visibility.

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

The extension should report version 7 and `State: ACTIVE`.

## Check behavior

On a normal, resizable window:

- Pin it; try title-bar and `Super` dragging, edge resizing, and the window menu's keyboard Move/Resize. Its frame should stay fixed. Try maximize and fullscreen too.
- Pin an already maximized or fullscreen window; attempts to restore it should retain its original state until unpinned.
- Toggle always-on-top with both the shortcut and window menu. Check red/blue/purple transitions and that other windows cover only non-above windows.
- Unpin all; above windows should keep their blue borders and move freely.
- Close a pinned window. Disable/enable the extension: pins should clear, while above windows regain blue borders.

Geometry/state restoration, move/resize cancellation, border state and lifecycle were integration-tested on GNOME Shell 50.5 with a GTK4 Wayland window in a headless compositor. Use the checks above for desktop input paths and visual behavior.
