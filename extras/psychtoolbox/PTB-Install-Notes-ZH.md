# Psychtoolbox 3 安装笔记
## Ubuntu/Debian + MATLAB + Wayland + NVIDIA

**测试环境：** Ubuntu 25.10，Linux kernel 6.17，MATLAB R2026a，NVIDIA GeForce RTX 5080（驱动 570.211.01），GNOME on Wayland

---

## 问题总览

| # | 问题 | 根本原因 | 解决方法 |
|---|------|---------|---------|
| 1 | `DownloadPsychtoolbox.m` 失败 | GitHub 于 2024 年 1 月关闭了 SVN 前端 | 下载 zip + `SetupPsychtoolbox` |
| 2 | MEX 文件无法加载（`Invalid MEX-file`） | Kernel 6.x 阻止可执行栈（`GNU_STACK RWE`） | `patchelf --clear-execstack` |
| 3 | `Screen()` 拒绝开窗 | PTB 检测到 XWayland 后硬性报错 | 取消 `WAYLAND_DISPLAY` + `ConserveVRAM` 标志 |
| 4 | `OpenWindow` 导致 MATLAB 崩溃 | MATLAB 自带 Mesa 软件渲染 libGL 优先于系统 NVIDIA | `LD_PRELOAD` 注入系统 NVIDIA libGL |
| 5 | `moglcore` 报错：找不到 `libglut.so.3` | Ubuntu 25.10 将包更名为 `libglut3.12` | 安装 + 修复软链接 |

---

## Step 1 — 安装系统依赖

```bash
sudo apt install -y patchelf libglut3.12

# Ubuntu 25.10 安装的是 libglut.so.3.12，但 PTB 期望 libglut.so.3 —— 手动创建软链接：
sudo ln -sf /usr/lib/x86_64-linux-gnu/libglut.so.3.12 \
            /usr/lib/x86_64-linux-gnu/libglut.so.3
```

> **注意：** Ubuntu ≤ 24.04 上使用 `sudo apt install freeglut3`，软链接会自动创建。

---

## Step 2 — 下载并解压 PTB

`DownloadPsychtoolbox.m` 已失效（GitHub 关闭了它依赖的 SVN 接口）。直接从 GitHub Release 下载 zip：

```bash
wget -O ~/Downloads/PTB-3.0.19.16.zip \
  "https://github.com/Psychtoolbox-3/Psychtoolbox-3/releases/download/3.0.19.16/3.0.19.16.zip"

mkdir -p ~/.matlab/toolbox
cd ~/.matlab/toolbox
unzip ~/Downloads/PTB-3.0.19.16.zip
```

---

## Step 3 — 运行 SetupPsychtoolbox

如果是在旧版本上重装，需要先清理 MATLAB 路径中的旧 PTB 条目（重装可能积累数百个重复路径，导致静默错误）：

```matlab
% 在 MATLAB 中执行 —— 清除所有 PTB 路径条目后重新 setup
p = path;
parts = strsplit(p, ':');
path(strjoin(parts(~contains(parts, 'Psychtoolbox')), ':'));
savepath;

cd('~/.matlab/toolbox/Psychtoolbox');
SetupPsychtoolbox(1);   % 1 = 非交互模式
```

---

## Step 4 — 修复 MEX 文件的可执行栈标志

**症状：**
```
Invalid MEX-file 'Screen.mexa64': cannot enable executable stack as shared object requires: Invalid argument
```

**原因：** PTB 的 MEX 二进制文件编译时带有 `GNU_STACK RWE`（可执行栈）标志。Linux kernel ≥ 6.x 的安全策略会在加载时拒绝此标志。

**修复：**
```bash
for f in ~/.matlab/toolbox/Psychtoolbox/PsychBasic/*.mexa64; do
    if patchelf --print-execstack "$f" 2>/dev/null | grep -q "X"; then
        patchelf --clear-execstack "$f"
        echo "Fixed: $(basename $f)"
    fi
done
```

---

## Step 5 — 强制使用 NVIDIA 硬件 OpenGL

**症状：** `Screen('OpenWindow')` 导致 MATLAB 崩溃（segfault），崩溃报告显示：
```
OpenGL: software
Graphics Driver: Uninitialized software
```

**原因：** MATLAB 在 `$MATLABROOT/sys/opengl/lib/glnxa64/libGL.so.1` 自带了 Mesa 软件渲染库，其优先级高于系统 NVIDIA 驱动（通过 `LD_LIBRARY_PATH`）。PTB 需要硬件 OpenGL，在软件渲染器上会直接崩溃。

**修复：** 在 `~/.zshrc`（或 `~/.bashrc`）中添加 alias，确保 MATLAB 始终以系统 libGL 启动：

```bash
# 强制使用系统 NVIDIA libGL —— 覆盖 MATLAB 自带的 Mesa 软件渲染器
alias matlab='DISPLAY=:0 WAYLAND_DISPLAY= \
  LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libGL.so.1:/usr/lib/x86_64-linux-gnu/libglut.so.3 \
  /usr/local/MATLAB/R2026a/bin/matlab'
```

根据实际安装路径调整 `/usr/local/MATLAB/R2026a/bin/matlab`。

---

## Step 6 — 配置 Wayland 支持

**症状：**
```
PTB-ERROR: You are trying to run a Screen() implementation meant *only* for a native XOrg X-Server
PTB-ERROR: under a XWayland fake X-Server. This is not supported.
```

**背景：** PTB 的 `Screen.mexa64` 只支持原生 Xorg。在 Wayland 桌面会话下，X11 客户端通过 XWayland（`DISPLAY=:0`）运行，PTB 检测到后直接拒绝。

### 方案 A —— 使用 Xorg 会话（正式实验推荐）

在登录界面点击齿轮图标，选择 **"GNOME on Xorg"** 或 **"Ubuntu on Xorg"**。在原生 Xorg 会话下，PTB 所有功能和时序保证均正常工作。

### 方案 B —— 强制 XWayland（仅供开发调试）

Step 5 中的 alias 已设置 `WAYLAND_DISPLAY=`（空值），可抑制 PTB 的 XWayland 检测。在 `~/Documents/MATLAB/startup.m` 中添加以下内容，在 MATLAB 启动时自动应用所需的 PTB 偏好：

```matlab
% 允许 Screen() 在 XWayland 下运行 —— 仅供开发，无时序保证
if isempty(getenv('WAYLAND_DISPLAY'))
    Screen('Preference', 'ConserveVRAM', 2^19);
end
```

> **警告：** 在 XWayland 下，`Screen('Flip')` 的时间戳不准确，偶尔可能卡死。可用于代码开发，不可用于正式数据采集。

---

## 全流程速查

```bash
# 系统依赖
sudo apt install -y patchelf libglut3.12
sudo ln -sf /usr/lib/x86_64-linux-gnu/libglut.so.3.12 \
            /usr/lib/x86_64-linux-gnu/libglut.so.3

# 下载 PTB
wget -O ~/Downloads/PTB-3.0.19.16.zip \
  "https://github.com/Psychtoolbox-3/Psychtoolbox-3/releases/download/3.0.19.16/3.0.19.16.zip"
mkdir -p ~/.matlab/toolbox && cd ~/.matlab/toolbox
unzip ~/Downloads/PTB-3.0.19.16.zip

# 修复 MEX execstack
for f in ~/.matlab/toolbox/Psychtoolbox/PsychBasic/*.mexa64; do
    patchelf --print-execstack "$f" 2>/dev/null | grep -q "X" && \
    patchelf --clear-execstack "$f" && echo "Fixed: $(basename $f)"
done
```

在 MATLAB 中执行：
```matlab
p = path; parts = strsplit(p, ':');
path(strjoin(parts(~contains(parts, 'Psychtoolbox')), ':'));
savepath;
cd('~/.matlab/toolbox/Psychtoolbox');
SetupPsychtoolbox(1);
```

`~/.zshrc`：
```bash
alias matlab='DISPLAY=:0 WAYLAND_DISPLAY= LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libGL.so.1:/usr/lib/x86_64-linux-gnu/libglut.so.3 /usr/local/MATLAB/R2026a/bin/matlab'
```

`~/Documents/MATLAB/startup.m`：
```matlab
if isempty(getenv('WAYLAND_DISPLAY'))
    Screen('Preference', 'ConserveVRAM', 2^19);
end
```

---

## 关于版本号显示

从 zip 安装的 PTB 会显示：
```
3.0.19 - Flavor: Manual Install, <date>
```
这是正常现象。`3.0.19` 对应所有 3.0.19.x 发行版；`.16` 后缀是 GitHub release tag，不是 PTB 内部版本号的组成部分。
