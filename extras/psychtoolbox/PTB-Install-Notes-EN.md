# Psychtoolbox 3 Installation Notes
## Ubuntu/Debian + MATLAB + Wayland + NVIDIA

**Tested on:** Ubuntu 25.10, Linux kernel 6.17, MATLAB R2026a, NVIDIA GeForce RTX 5080 (driver 570.211.01), GNOME on Wayland

---

## Issues and Fixes at a Glance

| # | Issue | Root Cause | Fix |
|---|-------|-----------|-----|
| 1 | `DownloadPsychtoolbox.m` fails | GitHub removed SVN frontend (Jan 2024) | Zip download + `SetupPsychtoolbox` |
| 2 | MEX files fail to load (`Invalid MEX-file`) | Kernel 6.x blocks executable stack (`GNU_STACK RWE`) | `patchelf --clear-execstack` |
| 3 | `Screen()` refuses to open window | PTB detects XWayland and hard-errors | Unset `WAYLAND_DISPLAY` + `ConserveVRAM` flag |
| 4 | MATLAB segfault on `Screen('OpenWindow')` | MATLAB ships its own Mesa software libGL | `LD_PRELOAD` system NVIDIA libGL |
| 5 | `moglcore` fails: `libglut.so.3` not found | Ubuntu 25.10 renamed package to `libglut3.12` | Install + fix symlink |

---

## Step 1 — Install System Dependencies

```bash
sudo apt install -y patchelf libglut3.12

# Ubuntu 25.10 installs libglut.so.3.12 but PTB expects libglut.so.3 — fix the symlink:
sudo ln -sf /usr/lib/x86_64-linux-gnu/libglut.so.3.12 \
            /usr/lib/x86_64-linux-gnu/libglut.so.3
```

> **Note:** On Ubuntu ≤ 24.04, use `sudo apt install freeglut3` instead — the symlink is created automatically.

---

## Step 2 — Download and Extract PTB

`DownloadPsychtoolbox.m` no longer works. GitHub permanently removed their Subversion frontend in January 2024. Use the GitHub release zip directly:

```bash
wget -O ~/Downloads/PTB-3.0.19.16.zip \
  "https://github.com/Psychtoolbox-3/Psychtoolbox-3/releases/download/3.0.19.16/3.0.19.16.zip"

mkdir -p ~/.matlab/toolbox
cd ~/.matlab/toolbox
unzip ~/Downloads/PTB-3.0.19.16.zip
```

---

## Step 3 — Run SetupPsychtoolbox

If reinstalling over an existing PTB, first clean stale path entries from MATLAB (a previous install can leave hundreds of duplicate entries that cause silent issues):

```matlab
% In MATLAB: remove all old PTB path entries, then run setup fresh
p = path;
parts = strsplit(p, ':');
path(strjoin(parts(~contains(parts, 'Psychtoolbox')), ':'));
savepath;

cd('~/.matlab/toolbox/Psychtoolbox');
SetupPsychtoolbox(1);   % 1 = non-interactive
```

---

## Step 4 — Fix Executable Stack on MEX Files

**Symptom:**
```
Invalid MEX-file 'Screen.mexa64': cannot enable executable stack as shared object requires: Invalid argument
```

**Cause:** PTB's MEX binaries were compiled with `GNU_STACK RWE` (executable stack required). Linux kernel ≥ 6.x rejects this at load time.

**Fix:**
```bash
for f in ~/.matlab/toolbox/Psychtoolbox/PsychBasic/*.mexa64; do
    if patchelf --print-execstack "$f" 2>/dev/null | grep -q "X"; then
        patchelf --clear-execstack "$f"
        echo "Fixed: $(basename $f)"
    fi
done
```

---

## Step 5 — Force NVIDIA Hardware OpenGL

**Symptom:** `Screen('OpenWindow')` crashes MATLAB with a segfault. Crash dump shows:
```
OpenGL: software
Graphics Driver: Uninitialized software
```

**Cause:** MATLAB ships its own Mesa software renderer at `$MATLABROOT/sys/opengl/lib/glnxa64/libGL.so.1`, which takes priority over the system NVIDIA driver via `LD_LIBRARY_PATH`. PTB requires hardware OpenGL and crashes on the software renderer.

**Fix:** Add an alias to `~/.zshrc` (or `~/.bashrc`) so MATLAB always starts with the system libGL preloaded:

```bash
# Force system NVIDIA libGL — overrides MATLAB's bundled Mesa software renderer
alias matlab='DISPLAY=:0 WAYLAND_DISPLAY= \
  LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libGL.so.1:/usr/lib/x86_64-linux-gnu/libglut.so.3 \
  /usr/local/MATLAB/R2026a/bin/matlab'
```

Adjust the MATLAB path (`/usr/local/MATLAB/R2026a/bin/matlab`) to match your installation.

---

## Step 6 — Configure for Wayland

**Symptom:**
```
PTB-ERROR: You are trying to run a Screen() implementation meant *only* for a native XOrg X-Server
PTB-ERROR: under a XWayland fake X-Server. This is not supported.
```

**Background:** PTB's `Screen.mexa64` only supports native Xorg. Under a Wayland desktop session, X11 clients run through XWayland (`DISPLAY=:0`), which PTB detects and rejects.

### Option A — Use an Xorg session (recommended for real experiments)

At the login screen, click the gear icon and select **"GNOME on Xorg"** or **"Ubuntu on Xorg"**. All PTB features and timing guarantees work correctly in a native Xorg session.

### Option B — Force XWayland (development only)

The alias in Step 5 already sets `WAYLAND_DISPLAY=` (empty), which suppresses PTB's XWayland detection. Add the following to `~/Documents/MATLAB/startup.m` to apply the required PTB preference at startup:

```matlab
% Allow Screen() under XWayland — development use only, no timing guarantees
if isempty(getenv('WAYLAND_DISPLAY'))
    Screen('Preference', 'ConserveVRAM', 2^19);
end
```

> **Warning:** Under XWayland, `Screen('Flip')` timestamps are inaccurate and the session may occasionally hang. Acceptable for code development, not for data collection.

---

## Complete Checklist

```bash
# System dependencies
sudo apt install -y patchelf libglut3.12
sudo ln -sf /usr/lib/x86_64-linux-gnu/libglut.so.3.12 \
            /usr/lib/x86_64-linux-gnu/libglut.so.3

# Download PTB
wget -O ~/Downloads/PTB-3.0.19.16.zip \
  "https://github.com/Psychtoolbox-3/Psychtoolbox-3/releases/download/3.0.19.16/3.0.19.16.zip"
mkdir -p ~/.matlab/toolbox && cd ~/.matlab/toolbox
unzip ~/Downloads/PTB-3.0.19.16.zip

# Fix MEX execstack
for f in ~/.matlab/toolbox/Psychtoolbox/PsychBasic/*.mexa64; do
    patchelf --print-execstack "$f" 2>/dev/null | grep -q "X" && \
    patchelf --clear-execstack "$f" && echo "Fixed: $(basename $f)"
done
```

In MATLAB:
```matlab
p = path; parts = strsplit(p, ':');
path(strjoin(parts(~contains(parts, 'Psychtoolbox')), ':'));
savepath;
cd('~/.matlab/toolbox/Psychtoolbox');
SetupPsychtoolbox(1);
```

`~/.zshrc`:
```bash
alias matlab='DISPLAY=:0 WAYLAND_DISPLAY= LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libGL.so.1:/usr/lib/x86_64-linux-gnu/libglut.so.3 /usr/local/MATLAB/R2026a/bin/matlab'
```

`~/Documents/MATLAB/startup.m`:
```matlab
if isempty(getenv('WAYLAND_DISPLAY'))
    Screen('Preference', 'ConserveVRAM', 2^19);
end
```

---

## Note on Version Reporting

PTB installed from a zip reports:
```
3.0.19 - Flavor: Manual Install, <date>
```
This is normal. `3.0.19` is the base version; `.16` is the GitHub release tag, not part of PTB's internal version scheme.
