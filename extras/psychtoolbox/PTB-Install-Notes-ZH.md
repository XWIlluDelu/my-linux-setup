# Psychtoolbox 3 安装笔记
## Agent Reference

适用环境：

- Debian sid
- MATLAB R2026a
- Wayland 桌面会话
- NVIDIA GPU

---

## 核心结论

- PTB 版本：`3.0.19.16` (`Last free dessert`)
- 安装位置：`~/.matlab/toolbox/Psychtoolbox`
- 该版本 **不包含** `PsychLicenseHandling` / online license management。
- **纯 Wayland 不可用**：保留 `WAYLAND_DISPLAY` 时，`Screen('OpenWindow')` 会因 XWayland fake X-Server 检查而拒绝运行。
- **开发机可用方案**：MATLAB launcher 清空 `WAYLAND_DISPLAY`，并预加载系统 `libGL/libglut`。
- 本机在 Debian `6.19` 内核下，多个 `.mexa64` 还需要额外清掉 `PT_GNU_STACK` execute bit，否则 `Screen.mexa64` 会报：

```text
Invalid MEX-file ... cannot enable executable stack
```

- 该方案已验证：
  - `PsychtoolboxVersion` 正常
  - `AssertOpenGL` 正常
  - `Screen('OpenWindow')` 可成功开窗
  - MATLAB 不 crash
- 该方案**不适合正式实验机**，因为 timing 仍不可靠。

---

## 关键文件

### 1. MATLAB launcher

路径：

```text
~/.local/bin/matlab
```

当前有效内容：

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

作用：

- 强制使用系统 `libGL/libglut`
- 隐藏 `WAYLAND_DISPLAY`，让 PTB 走 X11/XWayland 路径

### 2. MATLAB startup

路径：

```text
~/Documents/MATLAB/startup.m
```

当前有效内容：

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

作用：

- 保证 PTB path 进入 MATLAB
- 清理旧的/重复的 PTB path
- 在 workaround 模式下设置 `ConserveVRAM`
- 即使 PTB MEX 暂时坏掉，也不阻断 MATLAB 启动

### 3. 用户级 pathdef

路径：

```text
~/Documents/MATLAB/pathdef.m
```

作用：

- 不依赖 `/usr/local/MATLAB/.../pathdef.m` 的写权限
- 保证 fresh MATLAB 会话也能找到 PTB

---

## 安装流程

### 1. 下载并解压 PTB

```bash
curl -L -o ~/Downloads/PTB-3.0.19.16.zip \
  https://github.com/Psychtoolbox-3/Psychtoolbox-3/releases/download/3.0.19.16/3.0.19.16.zip

mkdir -p ~/.matlab/toolbox
rm -rf ~/.matlab/toolbox/Psychtoolbox
unzip -oq ~/Downloads/PTB-3.0.19.16.zip -d ~/.matlab/toolbox
```

### 2. 手工写入 MATLAB path

这里不直接跑 `SetupPsychtoolbox(1)`，因为它在 Linux 上会继续进入交互式
`PsychLinuxConfiguration`，不适合 agent 自动化。

改为直接把 PTB 加到当前 session path，然后写入用户级 `pathdef.m`：

```bash
/home/wangzixiong/.local/bin/matlab -batch "\
ptbRoot = fullfile(getenv('HOME'), '.matlab', 'toolbox', 'Psychtoolbox'); \
addpath(genpath(ptbRoot)); \
try, PsychJavaTrouble(1); catch ME, disp(ME.message); end; \
disp(savepath(fullfile(getenv('HOME'), 'Documents', 'MATLAB', 'pathdef.m')));"
```

说明：

- `PsychJavaTrouble(1)` 会更新 MATLAB 静态 Java classpath
- batch 模式下它会打印一个关于 `RETURN/ENTER` 的 warning，这是已知现象，不影响结果

### 3. 修复 `.mexa64` 的 executable-stack 标记

若 `Screen.mexa64` 报：

```text
Invalid MEX-file ... cannot enable executable stack
```

则运行：

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

### 4. 放置 3 个关键文件

- `~/.local/bin/matlab`
- `~/Documents/MATLAB/startup.m`
- `~/Documents/MATLAB/pathdef.m`

---

## 系统级配置

若只需要开发机可用、并且接受 warning，可先不做。

若需要更完整的 Linux 权限与实时调度配置，则执行：

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

可选：

```bash
sudo apt install gamemode
sudo cp ~/.matlab/toolbox/Psychtoolbox/PsychBasic/gamemode.ini /etc/gamemode.ini
```

之后 logout/login 或 reboot。

---

## 验证结果

本机已成功运行：

```matlab
AssertOpenGL;
Screen('Preference', 'SkipSyncTests', 2);
Screen('Preference', 'VisualDebugLevel', 3);
[win, rect] = PsychImaging('OpenWindow', max(Screen('Screens')), 0, [0 0 200 200]);
vbl = Screen('Flip', win);
WaitSecs(0.1);
Screen('CloseAll');
```

实测结论：

- `PsychtoolboxVersion` 正常
- `Screen('OpenWindow')` 成功
- MATLAB 不 crash
- `Screen('Version').os` 返回 `GNU/Linux X11`
- OpenGL renderer 识别到 NVIDIA RTX 5080

仍有 warning：

- Beamposition timestamping unavailable
- `Screen('Flip')` fallback to basic timestamping
- `SkipSyncTests = 2`

因此：

- **开发机可用**
- **实验机不可直接照搬**

---

## 常见问题速记

### `DownloadPsychtoolbox.m` 失效

直接下载 GitHub release zip，不要走旧 SVN 路线。

### `SetupPsychtoolbox(1)` 卡在 `savepath` 或 Linux 交互配置

本机不走 `SetupPsychtoolbox(1)`，直接手工 `addpath(genpath(...))` 后再写
`~/Documents/MATLAB/pathdef.m`。

### 纯 Wayland 下 `Screen('OpenWindow')` 拒绝运行

PTB 目前不接受这条路径。开发机使用 `WAYLAND_DISPLAY=` workaround + `ConserveVRAM(2^19)`。

### `OpenWindow` crash / software OpenGL

用系统 OpenGL：

```bash
LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libGL.so.1:/usr/lib/x86_64-linux-gnu/libglut.so.3
```

### `Invalid MEX-file ... executable stack`

本次 `3.0.19.16` 在 Debian `6.19` 内核下实际遇到，需要批量清掉所有
`.mexa64` 的 `PT_GNU_STACK` execute bit。直接用上面那段 Python patch。
