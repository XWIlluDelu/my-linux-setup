# Psychtoolbox 3 Installation Notes
## Agent Reference

Applies to:

- Debian sid
- MATLAB R2026a
- Wayland desktop session
- NVIDIA GPU

---

## Core Takeaways

- PTB version: `3.0.19.16` (`Last free dessert`)
- Install location: `~/.matlab/toolbox/Psychtoolbox`
- This version does **not** include `PsychLicenseHandling` / online license management.
- **Pure Wayland is not usable**: if `WAYLAND_DISPLAY` is preserved, `Screen('OpenWindow')` refuses to run because of the XWayland fake X-Server check.
- **Working dev-machine setup**: hide `WAYLAND_DISPLAY` in the MATLAB launcher and preload the system `libGL/libglut`.
- On this Debian `6.19` kernel, multiple `.mexa64` files also needed their `PT_GNU_STACK` execute bit cleared, otherwise `Screen.mexa64` failed with:

```text
Invalid MEX-file ... cannot enable executable stack
```

- This setup has been verified:
  - `PsychtoolboxVersion` works
  - `AssertOpenGL` works
  - `Screen('OpenWindow')` succeeds
  - MATLAB does not crash
- This setup is **not suitable for a real experiment machine**, because timing is still unreliable.

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
- hide `WAYLAND_DISPLAY` so PTB uses the X11/XWayland path

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
    try
        Screen('Preference', 'ConserveVRAM', 2^19);
    catch ME
        warning('PTB startup hook skipped: %s', ME.message);
    end
end
```

Purpose:

- ensure PTB is on the MATLAB path
- remove stale/duplicate PTB path entries
- set `ConserveVRAM` when the workaround path is active
- avoid blocking MATLAB startup if PTB MEX files are temporarily broken

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
curl -L -o ~/Downloads/PTB-3.0.19.16.zip \
  https://github.com/Psychtoolbox-3/Psychtoolbox-3/releases/download/3.0.19.16/3.0.19.16.zip

mkdir -p ~/.matlab/toolbox
rm -rf ~/.matlab/toolbox/Psychtoolbox
unzip -oq ~/Downloads/PTB-3.0.19.16.zip -d ~/.matlab/toolbox
```

### 2. Write the MATLAB path manually

This setup does **not** call `SetupPsychtoolbox(1)`, because on Linux it
continues into the interactive `PsychLinuxConfiguration` flow, which is
undesirable for scripted agent setup.

Instead, add PTB to the live session path directly and then write the
user-level `pathdef.m`:

```bash
/home/wangzixiong/.local/bin/matlab -batch "\
ptbRoot = fullfile(getenv('HOME'), '.matlab', 'toolbox', 'Psychtoolbox'); \
addpath(genpath(ptbRoot)); \
try, PsychJavaTrouble(1); catch ME, disp(ME.message); end; \
disp(savepath(fullfile(getenv('HOME'), 'Documents', 'MATLAB', 'pathdef.m')));"
```

Notes:

- `PsychJavaTrouble(1)` updates MATLAB's static Java classpath
- in batch mode it prints a `RETURN/ENTER` warning; this is expected and harmless

### 3. Fix the executable-stack flag on `.mexa64` files if needed

If `Screen.mexa64` fails with:

```text
Invalid MEX-file ... cannot enable executable stack
```

run:

```bash
python - <<'PY'
import struct
from pathlib import Path

PT_GNU_STACK = 0x6474E551
PF_X = 0x1
root = Path.home() / '.matlab' / 'toolbox' / 'Psychtoolbox'

for path in sorted(root.rglob('*.mexa64')):
    data = bytearray(path.read_bytes())
    if data[:4] != b'\x7fELF' or data[4] != 2:
        continue
    fmt = '<' if data[5] == 1 else '>'
    e_phoff = struct.unpack_from(fmt + 'Q', data, 32)[0]
    e_phentsize = struct.unpack_from(fmt + 'H', data, 54)[0]
    e_phnum = struct.unpack_from(fmt + 'H', data, 56)[0]
    changed = False
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        p_type, p_flags = struct.unpack_from(fmt + 'II', data, off)
        if p_type == PT_GNU_STACK and (p_flags & PF_X):
            struct.pack_into(fmt + 'I', data, off + 4, p_flags & ~PF_X)
            changed = True
    if changed:
        path.write_bytes(data)
        print('patched', path)
PY
```

### 4. Place the 3 key files

- `~/.local/bin/matlab`
- `~/Documents/MATLAB/startup.m`
- `~/Documents/MATLAB/pathdef.m`

---

## System-Level Configuration

If you only need a dev-machine setup and can tolerate warnings, you can skip
this initially.

If you need fuller Linux permissions and realtime scheduling support, run:

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

Successfully run on this machine:

```matlab
AssertOpenGL;
Screen('Preference', 'SkipSyncTests', 2);
Screen('Preference', 'VisualDebugLevel', 3);
[win, rect] = PsychImaging('OpenWindow', max(Screen('Screens')), 0, [0 0 200 200]);
vbl = Screen('Flip', win);
WaitSecs(0.1);
Screen('CloseAll');
```

Observed result:

- `PsychtoolboxVersion` works
- `Screen('OpenWindow')` succeeds
- MATLAB does not crash
- `Screen('Version').os` returns `GNU/Linux X11`
- OpenGL renderer identifies the NVIDIA RTX 5080 correctly

Remaining warnings:

- beamposition timestamping unavailable
- `Screen('Flip')` falls back to basic timestamping
- `SkipSyncTests = 2`

Therefore:

- **usable for a dev machine**
- **not directly suitable for an experiment machine**

---

## Common Issues

### `DownloadPsychtoolbox.m` is obsolete

Use the GitHub release zip directly. Do not rely on the old SVN-based flow.

### `SetupPsychtoolbox(1)` fails at `savepath` or interactive Linux setup

On this machine, skip `SetupPsychtoolbox(1)` completely. Instead, add PTB
with `addpath(genpath(...))` and then save `~/Documents/MATLAB/pathdef.m`.

### `Screen('OpenWindow')` refuses to run under pure Wayland

PTB does not accept that path here. On a dev machine, use the
`WAYLAND_DISPLAY=` workaround plus `ConserveVRAM(2^19)`.

### `OpenWindow` crash / software OpenGL

Force system OpenGL:

```bash
LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libGL.so.1:/usr/lib/x86_64-linux-gnu/libglut.so.3
```

### `Invalid MEX-file ... executable stack`

This **did** occur in the `3.0.19.16` setup on Debian `6.19`. Clear the
`PT_GNU_STACK` execute bit on all `.mexa64` files using the Python patch above.
