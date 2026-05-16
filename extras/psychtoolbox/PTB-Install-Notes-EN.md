# Psychtoolbox 3 Installation Notes

Applies to Debian sid, MATLAB R2026a, Wayland desktop session, and NVIDIA GPU.

## Conclusions

| Item | State |
|---|---|
| PTB version | `3.0.19.16` (`Last free dessert`) |
| Install location | `~/.matlab/toolbox/Psychtoolbox` |
| License management | This version does not include `PsychLicenseHandling` / online license management |
| Wayland | Pure Wayland is not usable; `Screen('OpenWindow')` is rejected by the XWayland fake X-Server check |
| Working dev-machine path | MATLAB launcher clears `WAYLAND_DISPLAY` and preloads system `libGL/libglut` |
| Experiment-machine suitability | Not suitable as-is; timing remains unreliable |

On Debian kernel `6.19`, multiple `.mexa64` files also need the `PT_GNU_STACK` executable bit cleared. Otherwise `Screen.mexa64` fails with:

```text
Invalid MEX-file ... cannot enable executable stack
```

## Key files

### `~/.local/bin/matlab`

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

if [[ "$#" -eq 0 ]]; then
  exec "$MATLAB_BIN" -desktop
fi

exec "$MATLAB_BIN" "$@"
```

### `~/Documents/MATLAB/startup.m`

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

### `~/Documents/MATLAB/pathdef.m`

User-level pathdef, avoiding write access requirements under `/usr/local/MATLAB/.../pathdef.m`.

## Install flow

Download and unpack:

```bash
curl -L -o ~/Downloads/PTB-3.0.19.16.zip \
  https://github.com/Psychtoolbox-3/Psychtoolbox-3/releases/download/3.0.19.16/3.0.19.16.zip
mkdir -p ~/.matlab/toolbox
rm -rf ~/.matlab/toolbox/Psychtoolbox
unzip -oq ~/Downloads/PTB-3.0.19.16.zip -d ~/.matlab/toolbox
```

Do not run `SetupPsychtoolbox(1)`; it enters an interactive Linux configuration path that is unsuitable for scripted agent setup. Write the user path manually:

```bash
/home/wangzixiong/.local/bin/matlab -batch "\
ptbRoot = fullfile(getenv('HOME'), '.matlab', 'toolbox', 'Psychtoolbox'); \
addpath(genpath(ptbRoot)); \
try, PsychJavaTrouble(1); catch ME, disp(ME.message); end; \
disp(savepath(fullfile(getenv('HOME'), 'Documents', 'MATLAB', 'pathdef.m')));"
```

If executable-stack errors occur, patch `.mexa64` files:

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

## Optional system-level configuration

A dev machine can skip this. For fuller Linux permissions and realtime scheduling support:

```bash
sudo groupadd --force psychtoolbox
sudo cp ~/.matlab/toolbox/Psychtoolbox/PsychBasic/psychtoolbox.rules /etc/udev/rules.d/
sudo cp ~/.matlab/toolbox/Psychtoolbox/PsychBasic/99-psychtoolboxlimits.conf /etc/security/limits.d/
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

Then log out/in or reboot.

## Verification

```matlab
AssertOpenGL;
Screen('Preference', 'SkipSyncTests', 2);
Screen('Preference', 'VisualDebugLevel', 3);
[win, rect] = PsychImaging('OpenWindow', max(Screen('Screens')), 0, [0 0 200 200]);
vbl = Screen('Flip', win);
WaitSecs(0.1);
Screen('CloseAll');
```

Verified: `PsychtoolboxVersion`, `AssertOpenGL`, and `Screen('OpenWindow')` work; MATLAB does not crash; `Screen('Version').os` returns `GNU/Linux X11`; the OpenGL renderer identifies the NVIDIA RTX 5080. Remaining warnings: beamposition timestamping unavailable, `Screen('Flip')` basic timestamping fallback, and `SkipSyncTests = 2`.

## Common issues

| Issue | Fix |
|---|---|
| `DownloadPsychtoolbox.m` is obsolete | Download the GitHub release zip directly |
| `SetupPsychtoolbox(1)` stalls | Do not run it; use `addpath(genpath(...))` and save user-level `pathdef.m` |
| Pure Wayland refuses `OpenWindow` | Use the `WAYLAND_DISPLAY=` workaround plus `ConserveVRAM(2^19)` |
| OpenWindow crash / software OpenGL | Preload system `libGL.so.1` and `libglut.so.3` |
| executable-stack error | Run the Python patch above |
