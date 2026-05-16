# Psychtoolbox 3 安装笔记

适用环境：Debian sid、MATLAB R2026a、Wayland 桌面会话、NVIDIA GPU。

## 结论

| 项 | 状态 |
|---|---|
| PTB 版本 | `3.0.19.16` (`Last free dessert`) |
| 安装位置 | `~/.matlab/toolbox/Psychtoolbox` |
| License 管理 | 此版本不包含 `PsychLicenseHandling` / online license management |
| Wayland | 纯 Wayland 不可用；`Screen('OpenWindow')` 会被 XWayland fake X-Server 检查拒绝 |
| 可用开发机方案 | MATLAB launcher 清空 `WAYLAND_DISPLAY`，并预加载系统 `libGL/libglut` |
| 实验机适用性 | 不适合正式实验机；timing 仍不可靠 |

Debian `6.19` 内核下，多个 `.mexa64` 需要清掉 `PT_GNU_STACK` executable bit，否则 `Screen.mexa64` 报：

```text
Invalid MEX-file ... cannot enable executable stack
```

## 关键文件

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

用户级 pathdef，避免依赖 `/usr/local/MATLAB/.../pathdef.m` 写权限。

## 安装流程

下载并解压：

```bash
curl -L -o ~/Downloads/PTB-3.0.19.16.zip \
  https://github.com/Psychtoolbox-3/Psychtoolbox-3/releases/download/3.0.19.16/3.0.19.16.zip
mkdir -p ~/.matlab/toolbox
rm -rf ~/.matlab/toolbox/Psychtoolbox
unzip -oq ~/Downloads/PTB-3.0.19.16.zip -d ~/.matlab/toolbox
```

不运行 `SetupPsychtoolbox(1)`；它会进入不适合自动化的 Linux 交互配置。手工写入用户 path：

```bash
/home/wangzixiong/.local/bin/matlab -batch "\
ptbRoot = fullfile(getenv('HOME'), '.matlab', 'toolbox', 'Psychtoolbox'); \
addpath(genpath(ptbRoot)); \
try, PsychJavaTrouble(1); catch ME, disp(ME.message); end; \
disp(savepath(fullfile(getenv('HOME'), 'Documents', 'MATLAB', 'pathdef.m')));"
```

如遇 executable-stack 错误，批量清理 `.mexa64`：

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

## 可选系统级配置

开发机可跳过。需要更完整 Linux 权限和 realtime scheduling 时执行：

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

可选：

```bash
sudo apt install gamemode
sudo cp ~/.matlab/toolbox/Psychtoolbox/PsychBasic/gamemode.ini /etc/gamemode.ini
```

之后重新登录或重启。

## 验证

```matlab
AssertOpenGL;
Screen('Preference', 'SkipSyncTests', 2);
Screen('Preference', 'VisualDebugLevel', 3);
[win, rect] = PsychImaging('OpenWindow', max(Screen('Screens')), 0, [0 0 200 200]);
vbl = Screen('Flip', win);
WaitSecs(0.1);
Screen('CloseAll');
```

已验证：`PsychtoolboxVersion`、`AssertOpenGL`、`Screen('OpenWindow')` 可用，MATLAB 不 crash，`Screen('Version').os` 返回 `GNU/Linux X11`，OpenGL renderer 识别 NVIDIA RTX 5080。保留警告：beamposition timestamping unavailable、`Screen('Flip')` basic timestamping fallback、`SkipSyncTests = 2`。

## 常见问题

| 问题 | 处理 |
|---|---|
| `DownloadPsychtoolbox.m` 失效 | 直接下载 GitHub release zip |
| `SetupPsychtoolbox(1)` 卡住 | 不运行；手工 `addpath(genpath(...))` 后保存用户级 `pathdef.m` |
| 纯 Wayland 下拒绝开窗 | 用 `WAYLAND_DISPLAY=` workaround + `ConserveVRAM(2^19)` |
| OpenWindow crash / software OpenGL | 预加载系统 `libGL.so.1` 和 `libglut.so.3` |
| executable stack 错误 | 运行上面的 Python patch |
