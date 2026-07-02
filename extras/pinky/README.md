# pinky

A self-written GNOME Shell extension. A shortcut pins the focused window's position and size; once pinned it cannot be moved or resized until unpinned. Notifications show `PINNED 📌` / `UNPINNED`.

## Scope

- Pins only window geometry (position + size); does not keep above and does not block close
- Default shortcut `Super+Shift+P`, changeable under GNOME Settings → Keyboard → Custom Shortcuts
- Targets the GNOME 45+ class-based extension model; tested on GNOME 50.2 / Wayland / mutter 18

## How it works

`end_grab_op` is not introspectable on this machine's mutter, so a grab cannot be cancelled synchronously when dragging starts. Instead, at pin time the window geometry is snapshotted and `Meta.Window`'s `position-changed` / `size-changed` are monitored; once the position changes, `move_resize_frame` restores the original rectangle synchronously inside the signal callback, before the compositor paints the next frame, so no displacement is visible. A `restoring` flag breaks the recursion that `move_resize_frame` would otherwise retrigger.

Maximize and fullscreen set state flags that override geometry (e.g. double-clicking the titlebar toggles maximize), so before restoring they are cleared with `unmaximize` / `unmake_fullscreen`.

On Wayland, window geometry changes are client-driven and asynchronous: `move_resize_frame` only sends an `xdg_toplevel` configure request and returns immediately, so the client acks and resizes on a later frame. This means any maximize request that reaches mutter is inevitably painted for at least one frame before an in-signal `move_resize_frame` restore can take effect — the `_restore` path above cannot prevent that flash by construction. It is retained only as a fallback so the window returns to its pinned rect after a maximize that enters through a path other than titlebar double-click (the maximize keybinding, the headerbar button).

The reported flash is the titlebar double-click. GTK headerbars read `org.gnome.desktop.wm.preferences::action-double-click-titlebar` (mapped to `gtk-titlebar-double-click`) to decide what a double-click does, and GSettings changes propagate live to every client via dconf. So the extension sets that key to `none` when the first window is pinned and restores the original value (default `toggle-maximize`) when the last window is unpinned. The maximize request is then never issued, so no maximized frame is ever painted. The tradeoff: while any window is pinned, double-clicking any window's titlebar does nothing — acceptable in a pin context and fully reversed on unpin.

For size changes that do reach a pinned window through other paths, GNOME Shell's crossfade is also suppressed. `windowManager.js` binds `this._sizeChangeWindow.bind(this)` at startup, so replacing that method name has no effect, but the bound body looks up `this._shouldAnimateActor` dynamically on every call; the extension overrides that instance property to return `false` for a pinned window, so `_sizeChangeWindow` takes the `completed_size_change` branch and prepares no animation info. Non-pinned windows fall through to the original gate unchanged.

`set_maximizeable` does not exist on `Meta.Window`, so a window cannot be made un-maximizeable at the capability level; the gsetting toggle is the only per-session way to prevent the double-click maximize at its source. Tested on GNOME 50 / Wayland.

## Installation

```bash
mkdir -p ~/.local/share/gnome-shell/extensions
cp -r extras/pinky ~/.local/share/gnome-shell/extensions/pinky@local
glib-compile-schemas ~/.local/share/gnome-shell/extensions/pinky@local/schemas
gnome-extensions enable pinky@local
```

On Wayland, GNOME Shell scans the extensions directory only at startup and cannot be hot-restarted, so log out and back in once for the extension to take effect.

## Usage

Focus the target window and press `Super+Shift+P`:

- Pin: notification shows `PINNED 📌` with the window title on the second line; the window cannot be moved or resized
- Unpin: press again; notification shows `UNPINNED`

## Verification

```bash
gnome-extensions info pinky@local | grep -E "Enabled|State"
```

Expect `State: ACTIVE`. After pinning, dragging the window should not move it; after unpinning it behaves normally again.

## Limitations

- Does not block the ❌ close button or `Alt+F4`; GNOME CSD title bars are drawn by the application and cannot be intercepted generically by a Shell extension
- Minimize, maximize (as a deliberate action), and move-to-workspace are not constrained by the pin
- The pinned geometry is the one captured at pin time; after unpin the window is freely movable again
