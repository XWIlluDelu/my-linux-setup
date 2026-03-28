# Wemeet 看不见别人共享屏幕：问题记录与解决方案

## 问题现象

- Ubuntu GNOME Wayland 会话下，腾讯会议可以正常进入会议。
- 能听到声音、能正常使用大部分功能。
- **看别人共享屏幕时为空白/黑屏/看不见内容**。

## 环境

- OS: Ubuntu 25.10
- Desktop: GNOME on Wayland
- Wemeet: 3.26.10.401 (`deb` 官方包)

## 根因分析

### 1. 官方 `deb` 默认并不走 native Wayland

`/opt/wemeet/wemeetapp.sh` 在检测到 Wayland 会话时，会主动设置：

```bash
export QT_QPA_PLATFORM=xcb
export XDG_SESSION_TYPE=x11
unset WAYLAND_DISPLAY
export WEMEET_XWAYLAND=1
```

也就是说，**官方 deb 在 Wayland 桌面上默认是 XWayland 模式运行**。

### 2. 黑屏不是因为流没收到，而是渲染失败

日志显示共享视频流已经成功接收并解码，但渲染阶段失败：

```text
eglCreateWindowSurface returned EGL_NO_SURFACE error:3005
```

这说明：

- 网络没问题
- 对方共享流已经到了本机
- 解码也成功了
- **真正失败的是显示到窗口表面的 EGL 渲染链路**

### 3. native Wayland 实验也不可靠

强制用 `QT_QPA_PLATFORM=wayland-egl` 直接启动 `/opt/wemeet/bin/wemeetapp` 后，
进程确实进入了 native Wayland，但很快触发：

```text
Signal: 11
SignalName: SIGSEGV
```

所以当前机器上：

- `native Wayland`：会崩
- `XWayland + 默认 NVIDIA EGL`：能启动，但看共享屏幕黑屏

### 4. 最终有效修复

对 **Wemeet 这个进程单独** 强制使用 Mesa EGL vendor：

```bash
__EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json
```

测试结果：

- `XWayland + Mesa EGL`：**能正常看到别人共享的屏幕**

## 最终解决方案

用下面的环境变量启动腾讯会议：

```bash
env __EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json /opt/wemeet/wemeetapp.sh
```

## 持久化方案

本机采用 **用户级永久覆盖**，不改系统包内容：

1. 新建启动脚本：`~/.local/bin/wemeet-mesa`
2. 新建桌面覆盖文件：`~/.local/share/applications/wemeetapp.desktop`
3. 让桌面图标和 `wemeet://` scheme handler 都走这个用户级启动器

## 新的启动脚本内容

```bash
#!/bin/sh
export __EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json
exec /opt/wemeet/wemeetapp.sh "$@"
```

## 结论

这不是会议本身问题，也不是普通的 Wayland 权限问题。

**根因是：Wemeet 在当前机器上的图形栈组合里，`NVIDIA EGL` 路径会导致共享屏幕渲染异常；对该应用单独切到 `Mesa EGL` 后恢复正常。**

## 备注

- 这是 **仅对 Wemeet 生效** 的修复，不会全局修改系统 EGL 行为。
- 若以后官方更新修复，可删除以下两个文件恢复默认行为：
  - `~/.local/bin/wemeet-mesa`
  - `~/.local/share/applications/wemeetapp.desktop`
