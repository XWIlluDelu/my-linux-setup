# pinky

A GNOME Shell extension. A shortcut pins the focused window's position and size; once pinned it cannot be moved, resized, maximized, or fullscreened until unpinned. Notifications show `PINNED 📌` / `UNPINNED`.

## Scope

- Pins only window geometry (position + size) and blocks maximize/fullscreen transitions on the pinned window; does not keep above and does not block close
- Default shortcut `Super+Shift+P` to toggle pin on the focused window, `Super+Shift+U` to unpin all at once; both changeable under GNOME Settings → Keyboard → Custom Shortcuts
- A hollow frame around each pinned window marks it persistently; the frame color follows the GNOME desktop accent color (GNOME 47+) and updates live when the accent changes
- Targets the GNOME 50 class-based extension model; tested on GNOME 50.2 / Wayland / mutter 18

## How it works

At pin time the window's frame rect is snapshotted and five `Meta.Window` signals are connected: `position-changed`, `size-changed`, `notify::maximized-horizontally`, `notify::maximized-vertically`, and `notify::fullscreen`. When any fires, `_restore` clears the maximize/fullscreen flags with `unmaximize` / `unmake_fullscreen` and calls `move_resize_frame` to put the window back at the pinned rect. A `restoring` flag breaks the recursion that `move_resize_frame` would otherwise retrigger.

The key timing insight: `notify::maximized-horizontally` and `notify::maximized-vertically` fire when the maximize **state flags** flip, which is *before* mutter commits the maximized geometry. `_restore` running in that handler cancels the transition synchronously, so the maximized frame is never painted and there is no flash. This is per-window — only the pinned window is affected; other windows maximize and double-click normally. An earlier attempt used `size-changed` alone, but that signal fires *after* the geometry is committed, so on Wayland (where geometry changes are client-driven and asynchronous) the maximized frame was inevitably painted for at least one frame before any restore could take effect.

`position-changed` and `size-changed` are kept as a fallback for move and resize grabs, where the geometry does change before the signal fires and `_restore` snaps the window back to the pinned rect.

For size changes that do reach a pinned window through a path the notify:: signals don't catch early enough, GNOME Shell's crossfade animation is also suppressed. The extension uses the official `InjectionManager` (GNOME Shell 44+) to override `WindowManager.prototype._shouldAnimateActor`, returning `false` for a pinned window so no animation info is prepared. `InjectionManager` keeps a stack of overrides, so the patch coexists with other extensions overriding the same method and restores cleanly on disable, instead of clobbering an instance property by hand. Non-pinned windows fall through to the original gate unchanged.

A persistent hollow frame marks each pinned window. It is a non-reactive `St.Widget` added as a child of the window's own `MetaWindowActor`, so it stacks, hides, and is destroyed together with the window — mutter restacks only window actors, so a sibling in `global.window_group` would get thrown above other windows on focus changes, but a child moves with its parent and stays correctly ordered. The frame is positioned just outside the window's frame rect (child coordinates are relative to the actor origin, the buffer rect including the client shadow margin). Only a 2px border is drawn; no `box-shadow`, because St renders box-shadow on large actors by 9-slice stretching a small blurred texture, which fills a hollow interior with a translucent tint. The border color is read from `org.gnome.desktop.interface::accent-color` (GNOME 47+) and updated live when the desktop accent changes.

`set_maximizeable` does not exist on `Meta.Window`, so a window cannot be made un-maximizeable at the capability level; the notify:: signal interception is the per-window mechanism. Tested on GNOME 50 / Wayland.

## Installation

```bash
mkdir -p ~/.local/share/gnome-shell/extensions
cp -r extras/pinky ~/.local/share/gnome-shell/extensions/pinky@local
glib-compile-schemas ~/.local/share/gnome-shell/extensions/pinky@local/schemas
gnome-extensions enable pinky@local
```

On Wayland, GNOME Shell scans the extensions directory only at startup and cannot be hot-restarted, so log out and back in once for the extension to take effect.

## Usage

- `Super+Shift+P` on the focused window toggles pin: notification shows `PINNED 📌` with the window title on the second line; a hollow frame appears around it; the window cannot be moved, resized, maximized, or fullscreened
- `Super+Shift+U` unpins every pinned window at once: notification shows `UNPINNED ALL` with the count

## Verification

```bash
gnome-extensions info pinky@local | grep -E "Enabled|State"
```

Expect `State: ACTIVE`. After pinning, dragging the window should not move it; double-clicking its titlebar should not maximize it; other windows behave normally.

## Limitations

- Does not block the close button or `Alt+F4`; GNOME CSD title bars are drawn by the application and cannot be intercepted generically by a Shell extension
- Minimize and move-to-workspace are not constrained by the pin
- The pinned geometry is the one captured at pin time; after unpin the window is freely movable again
