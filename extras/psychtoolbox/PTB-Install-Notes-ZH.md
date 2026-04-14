# Psychtoolbox 3 安装笔记
## Agent Reference

适用环境：

- Debian sid
- MATLAB R2026a
- Wayland 桌面会话
- NVIDIA GPU

---

## 核心结论

- PTB 版本：`3.0.22.2`
- 安装位置：`~/.matlab/toolbox/Psychtoolbox`
- **纯 Wayland 不可用**：保留 `WAYLAND_DISPLAY` 时，`Screen('OpenWindow')` 会因 XWayland fake X-Server 检查而拒绝运行。
- **开发机可用方案**：MATLAB 在 Wayland 桌面中启动，但 launcher 清空 `WAYLAND_DISPLAY`，并在 `startup.m` 中设置 `ConserveVRAM(2^19)`。
- 该方案已验证：
  - `AssertOpenGL` 正常
  - `Screen('OpenWindow')` 可成功开窗
  - MATLAB 不 crash
- 该方案**不适合正式实验机**，因为 timing 仍不可靠。
- 当前 PTB 预编译 MEX 需要 `PsychLicenseHandling('Setup')`，可先用 free trial。

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
- 隐藏 `WAYLAND_DISPLAY`，让 PTB 走 XWayland workaround

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
    Screen('Preference', 'ConserveVRAM', 2^19);
end
```

作用：

- 保证 PTB path 进入 MATLAB
- 清理旧的/重复的 PTB path
- 在 workaround 模式下设置 `ConserveVRAM`

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
curl -L -o ~/Downloads/PTB-3.0.22.2.zip \
  https://github.com/Psychtoolbox-3/Psychtoolbox-3/releases/download/3.0.22.2/3.0.22.2.zip

mkdir -p ~/.matlab/toolbox
unzip -oq ~/Downloads/PTB-3.0.22.2.zip -d ~/.matlab/toolbox
```

### 2. 处理 `SetupPsychtoolbox(1)` 的 `savepath` 权限问题

`SetupPsychtoolbox(1)` 默认想写：

```text
/usr/local/MATLAB/R2026a/toolbox/local/pathdef.m
```

普通用户不可写，所以先做：

```bash
cp /usr/local/MATLAB/R2026a/toolbox/local/pathdef.m \
  ~/.matlab/toolbox/Psychtoolbox/pathdef.m

chmod u+w ~/.matlab/toolbox/Psychtoolbox/pathdef.m
```

然后运行：

```bash
matlab -batch "cd(fullfile(getenv('HOME'), '.matlab', 'toolbox', 'Psychtoolbox')); SetupPsychtoolbox(1);"
```

再保存用户级 path：

```bash
matlab -batch "disp(savepath(fullfile(getenv('HOME'), 'Documents', 'MATLAB', 'pathdef.m')))"
```

最后删掉临时文件：

```bash
rm ~/.matlab/toolbox/Psychtoolbox/pathdef.m
```

### 3. 启用 license management

在 MATLAB 中运行：

```matlab
PsychLicenseHandling('Setup')
```

流程：

- 同意 online license management
- 输入 license key / credentials，或者直接回车启用 free trial

### 4. 放置 3 个关键文件

- `~/.local/bin/matlab`
- `~/Documents/MATLAB/startup.m`
- `~/Documents/MATLAB/pathdef.m`

---

## 系统级配置

执行：

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

已成功运行：

```matlab
AssertOpenGL;
[win, rect] = PsychImaging('OpenWindow', max(Screen('Screens')), 0);
vbl = Screen('Flip', win);
WaitSecs(0.2);
Screen('CloseAll');
```

实测结论：

- `Screen('OpenWindow')` 成功
- MATLAB 不 crash
- `Screen('Version').os` 返回 `GNU/Linux X11`
- OpenGL renderer 识别到 NVIDIA RTX 5080

仍有 warning：

- Beamposition timestamping unavailable
- `Screen('Flip')` fallback to basic timestamping
- suspected triple buffering

因此：

- **开发机可用**
- **实验机不可直接照搬**

---

## 常见问题速记

### `DownloadPsychtoolbox.m` 失效

直接下载 GitHub release zip，不要走旧 SVN 路线。

### `SetupPsychtoolbox(1)` 卡在 `savepath`

先放临时 `pathdef.m` 到 PTB 根目录，再把最终 path 保存到 `~/Documents/MATLAB/pathdef.m`。

### 纯 Wayland 下 `Screen('OpenWindow')` 拒绝运行

PTB 目前不接受这条路径。开发机使用 `WAYLAND_DISPLAY=` workaround + `ConserveVRAM(2^19)`。

### `OpenWindow` crash / software OpenGL

用系统 OpenGL：

```bash
LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libGL.so.1:/usr/lib/x86_64-linux-gnu/libglut.so.3
```

### `Invalid MEX-file ... executable stack`

本次 `3.0.22.2` 没遇到，但若未来复现，可试：

```bash
for f in ~/.matlab/toolbox/Psychtoolbox/PsychBasic/*.mexa64; do
  if patchelf --print-execstack "$f" 2>/dev/null | grep -q "X"; then
    patchelf --clear-execstack "$f"
  fi
done
```
