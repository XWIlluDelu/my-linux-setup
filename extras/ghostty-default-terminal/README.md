# ghostty-default-terminal

把 Ghostty 设为常见 Linux 桌面栈下的默认终端，作为独立 extra 脚本存在，不接入 `manage.sh` 主流程。

## 用法

预览：

```bash
bash ~/my-linux-setup/extras/ghostty-default-terminal/ghostty-default-terminal.sh --check
```

应用：

```bash
bash ~/my-linux-setup/extras/ghostty-default-terminal/ghostty-default-terminal.sh --apply
```

如果还想顺手设置 Debian/Ubuntu 的 `x-terminal-emulator`：

```bash
bash ~/my-linux-setup/extras/ghostty-default-terminal/ghostty-default-terminal.sh --apply --set-alternatives
```

## 覆盖范围

- **GNOME / Nautilus**：优先走 `xdg-terminal-exec`
- **KDE / Dolphin**：设置默认外部终端
- **XFCE / Thunar**：写 helper 配置
- **Cinnamon / Nemo**：best-effort

## 注意

- 建议直接以目标桌面用户身份运行，不要用 root 用户改到错误的 `$HOME`。
- 这件事主要和**桌面环境 / 文件管理器**有关，不只是 distro 本身。
- GNOME/Nautilus 在不同发行版上的实现会有 patch 差异；脚本已经尽量做了兼容分支。
- Nemo 对 Ghostty 的支持不完全稳定，因此 Cinnamon 分支不能保证 100% 生效。
