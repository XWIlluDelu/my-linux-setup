# Psychtoolbox 3 Installation Notes

Recorded workstation setup: Debian sid, MATLAB R2026a, a Wayland session, and an NVIDIA GPU. It retains a pinned older PTB version and local workarounds for development, not a recommendation for a new timing-critical experiment machine.

For a new installation, consult the current [PTB download instructions](https://psychtoolbox.org/download.html) and [version/support matrix](https://psychtoolbox.org/versions.html). PTB 3.0.20 introduced paid licensing for macOS/Windows, not Linux; avoiding those licenses is not a reason to pin this Linux machine to 3.0.19.16. Keep an existing experiment's version fixed until its behavior and timing have been revalidated.

## Recorded results

| Item | State |
|---|---|
| PTB version | `3.0.19.16` (`Last free dessert`) |
| Install location | `~/.matlab/toolbox/Psychtoolbox` |
| License management | This version does not include `PsychLicenseHandling` / online license management |
| Wayland | In this setup, `Screen('OpenWindow')` was rejected by the XWayland fake X-Server check |
| Working dev-machine path | MATLAB launcher clears `WAYLAND_DISPLAY` and preloads system `libGL/libglut` |
| Experiment-machine suitability | Not suitable as-is; timing remains unreliable |

In the recorded Debian kernel `6.19` environment, multiple `.mexa64` files needed the `PT_GNU_STACK` executable bit cleared. Otherwise `Screen.mexa64` fails with:

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

To reproduce the recorded version, first move any existing toolbox aside rather than deleting it:

```bash
mkdir -p ~/Downloads
curl -fL -o ~/Downloads/PTB-3.0.19.16.zip \
  https://github.com/Psychtoolbox-3/Psychtoolbox-3/releases/download/3.0.19.16/3.0.19.16.zip
mkdir -p ~/.matlab/toolbox
if [[ -e ~/.matlab/toolbox/Psychtoolbox ]]; then
  mv ~/.matlab/toolbox/Psychtoolbox ~/.matlab/toolbox/Psychtoolbox.backup-"$(date +%Y%m%d-%H%M%S)"
fi
unzip -oq ~/Downloads/PTB-3.0.19.16.zip -d ~/.matlab/toolbox
```

`SetupPsychtoolbox(1)` is interactive. The recorded unattended setup instead wrote the user path manually; an interactive installation should follow the upstream setup instructions:

```bash
~/.local/bin/matlab -batch "\
ptbRoot = fullfile(getenv('HOME'), '.matlab', 'toolbox', 'Psychtoolbox'); \
addpath(genpath(ptbRoot)); \
try, PsychJavaTrouble(1); catch ME, disp(ME.message); end; \
disp(savepath(fullfile(getenv('HOME'), 'Documents', 'MATLAB', 'pathdef.m')));"
```

If executable-stack errors occur, patch `.mexa64` files:

```bash
python3 - <<'PY'
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
sudo usermod -a -G psychtoolbox "$USER"
sudo usermod -a -G dialout "$USER"
sudo usermod -a -G lp "$USER"
sudo udevadm control --reload
sudo udevadm trigger
```

Optional:

```bash
sudo apt install gamemode
sudo cp ~/.matlab/toolbox/Psychtoolbox/PsychBasic/gamemode.ini /etc/gamemode.ini
```

Then log out/in or reboot.

## Development smoke test

`SkipSyncTests = 2` deliberately bypasses synchronization checks. This only tests that a window opens; it does not validate stimulus timing. Do not carry it into data collection. Use upstream timing tests and suitable display/hardware measurements on the experiment machine.

```matlab
AssertOpenGL;
Screen('Preference', 'SkipSyncTests', 2);
Screen('Preference', 'VisualDebugLevel', 3);
[win, rect] = PsychImaging('OpenWindow', max(Screen('Screens')), 0, [0 0 200 200]);
vbl = Screen('Flip', win);
WaitSecs(0.1);
Screen('CloseAll');
```

In the recorded test, `PsychtoolboxVersion`, `AssertOpenGL`, and `Screen('OpenWindow')` worked without crashing MATLAB. `Screen('Version').os` returned `GNU/Linux X11` and the OpenGL renderer identified the NVIDIA RTX 5080. Remaining warnings: beamposition timestamping unavailable, `Screen('Flip')` basic timestamping fallback, and `SkipSyncTests = 2`.

## Common issues

| Issue | Fix |
|---|---|
| `DownloadPsychtoolbox.m` is obsolete | Download the GitHub release zip directly |
| `SetupPsychtoolbox(1)` waits in unattended execution | Run its interactive setup manually, or reproduce the local user-path setup above |
| Recorded Wayland setup refuses `OpenWindow` | The development-only workaround used `WAYLAND_DISPLAY=` plus `ConserveVRAM(2^19)`; it does not establish reliable timing |
| OpenWindow crash / software OpenGL | Preload system `libGL.so.1` and `libglut.so.3` |
| executable-stack error | Run the Python patch above |
