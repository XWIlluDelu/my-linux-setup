# Pinky

Pinky v5 is a GNOME Shell extension that pins the focused window's geometry or keeps it always on top. It targets GNOME Shell 50; the local build is active on GNOME 50.2 / Wayland.

## Shortcuts

| Shortcut | Action |
|---|---|
| `Super+Shift+P` | Toggle geometry pin on the focused window |
| `Super+Shift+T` | Toggle always-on-top on the focused window |
| `Super+Shift+U` | Unpin every pinned window |

The shortcuts are configurable under GNOME Settings → Keyboard → Custom Shortcuts.

A 2px border marks managed windows: red for pinned, blue for always-on-top, and purple for both. Always-on-top state survives extension disable/enable; pins do not.

## Behavior

At pin time, Pinky snapshots the window frame rectangle. Geometry and maximize/fullscreen state changes restore that rectangle synchronously. It suppresses the Shell size-change animation only for pinned windows, preventing a visible maximization flash.

The indicator is a child of the window's `MetaWindowActor`, so it tracks the window's stacking, visibility, and lifetime. Windows are tracked while the extension is enabled so changes made through the Shell window menu also update their always-on-top border.

## Installation

```bash
mkdir -p ~/.local/share/gnome-shell/extensions
cp -r extras/pinky ~/.local/share/gnome-shell/extensions/pinky@local
glib-compile-schemas ~/.local/share/gnome-shell/extensions/pinky@local/schemas
gnome-extensions enable pinky@local
```

On Wayland, GNOME Shell scans extensions only at login. Log out and back in after installation.

## Verification

```bash
gnome-extensions info pinky@local | grep -E 'Version|Enabled|State'
```

Expect version 5 and `State: ACTIVE`. Pin a window and verify that dragging, resizing, maximizing, and fullscreening restore its geometry. Toggle always-on-top by shortcut and through the Shell window menu; its border must stay synchronized.

## Limitations

- Pinky does not block closing, minimizing, or moving a window to another workspace.
- Application title bars are client-side and cannot be intercepted generically.
- `_shouldAnimateActor` is a private GNOME Shell method. Recheck it before porting to GNOME 51.
