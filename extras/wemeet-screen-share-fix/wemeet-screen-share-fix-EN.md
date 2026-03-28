# Wemeet Cannot View Others' Shared Screen: Issue Log and Fix

## Symptom

- On Ubuntu GNOME Wayland, Wemeet can join meetings normally.
- Audio and most other features work.
- **Other participants' shared screens appear blank / black / invisible.**

## Environment

- OS: Ubuntu 25.10
- Desktop: GNOME on Wayland
- Wemeet: 3.26.10.401 (official `deb` package)

## Root Cause Analysis

### 1. The official `deb` does not run in native Wayland by default

When `/opt/wemeet/wemeetapp.sh` detects a Wayland session, it explicitly sets:

```bash
export QT_QPA_PLATFORM=xcb
export XDG_SESSION_TYPE=x11
unset WAYLAND_DISPLAY
export WEMEET_XWAYLAND=1
```

So the official `deb` actually runs in **XWayland mode** on a Wayland desktop.

### 2. The problem is not missing stream data; it is a rendering failure

The logs show that the screen-sharing video stream is received and decoded successfully, but rendering fails at the window-surface stage:

```text
eglCreateWindowSurface returned EGL_NO_SURFACE error:3005
```

This means:

- the network is fine
- the remote shared stream reaches the local machine
- decoding succeeds
- **the actual failure happens in the EGL rendering path used to display the image**

### 3. Native Wayland is also unstable in this environment

When forcing `/opt/wemeet/bin/wemeetapp` to start with `QT_QPA_PLATFORM=wayland-egl`,
the process does enter native Wayland, but soon crashes with:

```text
Signal: 11
SignalName: SIGSEGV
```

So on this machine:

- `native Wayland`: crashes
- `XWayland + default NVIDIA EGL`: starts, but screen sharing is black

### 4. The working fix

Force **only the Wemeet process** to use the Mesa EGL vendor:

```bash
__EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json
```

Result:

- `XWayland + Mesa EGL`: **can correctly display others' shared screens**

## Final Fix

Launch Wemeet with:

```bash
env __EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json /opt/wemeet/wemeetapp.sh
```

## Persistent Setup

This machine uses a **user-level permanent override** without modifying the system package itself:

1. Create a wrapper script: `~/.local/bin/wemeet-mesa`
2. Create a user desktop override: `~/.local/share/applications/wemeetapp.desktop`
3. Make both the launcher icon and `wemeet://` URL handler use this wrapper

## Wrapper Script

```bash
#!/bin/sh
export __EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json
exec /opt/wemeet/wemeetapp.sh "$@"
```

## Conclusion

This is not a meeting-side problem and not a simple Wayland permission issue.

**The root cause is that Wemeet's rendering path is broken with the current NVIDIA EGL path on this machine; forcing Mesa EGL only for Wemeet restores correct screen-share rendering.**

## Notes

- This fix applies **only to Wemeet** and does not change the system-wide EGL behavior.
- If an official future update fixes the issue, remove these two files to restore default behavior:
  - `~/.local/bin/wemeet-mesa`
  - `~/.local/share/applications/wemeetapp.desktop`
