# Psychtoolbox 3 Installation Notes
## Agent Reference

Applies to:

- Debian sid
- MATLAB R2026a
- Wayland desktop session
- NVIDIA GPU

---

## Core Takeaways

- PTB version: `3.0.22.2`
- Install location: `~/.matlab/toolbox/Psychtoolbox`
- **Pure Wayland is not usable**: if `WAYLAND_DISPLAY` is preserved, `Screen('OpenWindow')` refuses to run because of the XWayland fake X-Server check.
- **Working dev-machine setup**: keep the desktop on Wayland, but hide `WAYLAND_DISPLAY` in the MATLAB launcher and set `ConserveVRAM(2^19)` in `startup.m`.
- This setup has been verified:
  - `AssertOpenGL` works
  - `Screen('OpenWindow')` succeeds
  - MATLAB does not crash
- This setup is **not suitable for a real experiment machine**, because timing is still unreliable.
- Current prebuilt PTB MEX files require `PsychLicenseHandling('Setup')`; a free trial can be used initially.

---

## Key Files

### 1. MATLAB launcher

Path:

```text
~/.local/bin/matlab
```

Current working content:

```bash
#!/usr/bin/env bash

set -euo pipefail

MATLAB_BIN="/usr/local/MATLAB/R2026a/bin/matlab"
SYSTEM_LIBGL="/usr/lib/x86_64-linux-gnu/libGL.so.1"
SYSTEM_LIBGLUT="/usr/lib/x86_64-linux-gnu/libglut.so.3"

if [[ ! -x "$MATLAB_BIN" ]]; then
  echo "MATLAB executable not found at $MATLAB_BIN" >&2
  exit 1
fi

if [[ -r "$SYSTEM_LIBGL" && -r "$SYSTEM_LIBGLUT" ]]; then
  if [[ -n "${LD_PRELOAD:-}" ]]; then
    export LD_PRELOAD="${SYSTEM_LIBGL}:${SYSTEM_LIBGLUT}:${LD_PRELOAD}"
  else
    export LD_PRELOAD="${SYSTEM_LIBGL}:${SYSTEM_LIBGLUT}"
  fi
fi

if [[ -n "${DISPLAY:-}" ]]; then
  export WAYLAND_DISPLAY=
fi

exec "$MATLAB_BIN" "$@"
```

Purpose:

- force system `libGL/libglut`
- hide `WAYLAND_DISPLAY` so PTB uses the XWayland workaround path

### 2. MATLAB startup

Path:

```text
~/Documents/MATLAB/startup.m
```

Current working content:

```matlab
% Local MATLAB startup for Psychtoolbox on Debian sid.

ptbCandidates = {
    fullfile(getenv('HOME'), '.matlab', 'toolbox', 'Psychtoolbox')
    '/usr/share/psychtoolbox-3'
};

ptbRoot = '';
for idx = 1:numel(ptbCandidates)
    if isfolder(ptbCandidates{idx})
        ptbRoot = ptbCandidates{idx};
        break;
    end
end

if ~isempty(ptbRoot)
    pathEntries = strsplit(path, pathsep);
    for idx = 1:numel(pathEntries)
        entry = pathEntries{idx};
        if contains(entry, 'Psychtoolbox') && ~startsWith(entry, ptbRoot)
            if isfolder(entry)
                rmpath(entry);
            end
        end
    end

    if isempty(which('PsychtoolboxVersion'))
        addpath(genpath(ptbRoot));
    end
end

if isempty(getenv('WAYLAND_DISPLAY')) && ~isempty(which('Screen'))
    Screen('Preference', 'ConserveVRAM', 2^19);
end
```

Purpose:

- ensure PTB is on the MATLAB path
- remove stale/duplicate PTB path entries
- set `ConserveVRAM` when the workaround path is active

### 3. User-level pathdef

Path:

```text
~/Documents/MATLAB/pathdef.m
```

Purpose:

- avoid relying on write access to `/usr/local/MATLAB/.../pathdef.m`
- make fresh MATLAB sessions reliably find PTB

---

## Install Flow

### 1. Download and unpack PTB

```bash
curl -L -o ~/Downloads/PTB-3.0.22.2.zip \
  https://github.com/Psychtoolbox-3/Psychtoolbox-3/releases/download/3.0.22.2/3.0.22.2.zip

mkdir -p ~/.matlab/toolbox
unzip -oq ~/Downloads/PTB-3.0.22.2.zip -d ~/.matlab/toolbox
```

### 2. Work around the `SetupPsychtoolbox(1)` `savepath` permission issue

`SetupPsychtoolbox(1)` tries to write:

```text
/usr/local/MATLAB/R2026a/toolbox/local/pathdef.m
```

Normal users cannot write there, so first place a temporary `pathdef.m` in the PTB root:

```bash
cp /usr/local/MATLAB/R2026a/toolbox/local/pathdef.m \
  ~/.matlab/toolbox/Psychtoolbox/pathdef.m

chmod u+w ~/.matlab/toolbox/Psychtoolbox/pathdef.m
```

Then run:

```bash
matlab -batch "cd(fullfile(getenv('HOME'), '.matlab', 'toolbox', 'Psychtoolbox')); SetupPsychtoolbox(1);"
```

Then save the final user-level path:

```bash
matlab -batch "disp(savepath(fullfile(getenv('HOME'), 'Documents', 'MATLAB', 'pathdef.m')))"
```

Finally remove the temporary file:

```bash
rm ~/.matlab/toolbox/Psychtoolbox/pathdef.m
```

### 3. Enable license management

Run inside MATLAB:

```matlab
PsychLicenseHandling('Setup')
```

Flow:

- consent to online license management
- enter a paid key / credentials, or just press Enter for a free trial

### 4. Place the 3 key files

- `~/.local/bin/matlab`
- `~/Documents/MATLAB/startup.m`
- `~/Documents/MATLAB/pathdef.m`

---

## System-Level Configuration

Run:

```bash
sudo groupadd --force psychtoolbox

sudo cp ~/.matlab/toolbox/Psychtoolbox/PsychBasic/psychtoolbox.rules \
  /etc/udev/rules.d/

sudo cp ~/.matlab/toolbox/Psychtoolbox/PsychBasic/99-psychtoolboxlimits.conf \
  /etc/security/limits.d/

sudo usermod -a -G psychtoolbox wangzixiong
sudo usermod -a -G dialout wangzixiong
sudo usermod -a -G lp wangzixiong

sudo udevadm control --reload
sudo udevadm trigger
```

Optional:

```bash
sudo apt install gamemode
sudo cp ~/.matlab/toolbox/Psychtoolbox/PsychBasic/gamemode.ini /etc/gamemode.ini
```

Then log out / log back in or reboot.

---

## Verification Result

Successfully run:

```matlab
AssertOpenGL;
[win, rect] = PsychImaging('OpenWindow', max(Screen('Screens')), 0);
vbl = Screen('Flip', win);
WaitSecs(0.2);
Screen('CloseAll');
```

Observed result:

- `Screen('OpenWindow')` succeeds
- MATLAB does not crash
- `Screen('Version').os` returns `GNU/Linux X11`
- OpenGL renderer identifies the NVIDIA RTX 5080 correctly

Remaining warnings:

- beamposition timestamping unavailable
- `Screen('Flip')` falls back to basic timestamping
- suspected triple buffering

Therefore:

- **usable for a dev machine**
- **not directly suitable for an experiment machine**

---

## Common Issues

### `DownloadPsychtoolbox.m` is obsolete

Use the GitHub release zip directly. Do not rely on the old SVN-based flow.

### `SetupPsychtoolbox(1)` fails at `savepath`

Place a temporary `pathdef.m` in the PTB root, then save the final path into `~/Documents/MATLAB/pathdef.m`.

### `Screen('OpenWindow')` refuses to run under pure Wayland

PTB does not accept that path here. On a dev machine, use the `WAYLAND_DISPLAY=` workaround plus `ConserveVRAM(2^19)`.

### `OpenWindow` crash / software OpenGL

Force system OpenGL:

```bash
LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libGL.so.1:/usr/lib/x86_64-linux-gnu/libglut.so.3
```

### `Invalid MEX-file ... executable stack`

Not hit in this `3.0.22.2` setup, but if it appears later:

```bash
for f in ~/.matlab/toolbox/Psychtoolbox/PsychBasic/*.mexa64; do
  if patchelf --print-execstack "$f" 2>/dev/null | grep -q "X"; then
    patchelf --clear-execstack "$f"
  fi
done
```
