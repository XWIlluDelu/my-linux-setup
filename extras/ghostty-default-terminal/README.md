# ghostty-default-terminal

把 `ghostty` 设为 GNOME 下的默认终端。这里只保留当前验证过的最小方案。

## 原则

- GNOME 默认终端继续走 `xdg-terminal-exec`
- `xdg-terminal-exec` 的用户级目标改成 `ghostty`
- 这里只处理“默认终端”，不处理文件浏览器右键菜单增强

## 步骤

确认 `ghostty` 的 desktop file 存在：

```bash
ls /usr/share/applications/com.mitchellh.ghostty.desktop
```

写入 `xdg-terminal-exec` 用户配置：

```bash
mkdir -p ~/.config
printf '%s\n' 'com.mitchellh.ghostty.desktop' > ~/.config/xdg-terminals.list
printf '%s\n' 'com.mitchellh.ghostty.desktop' > ~/.config/gnome-xdg-terminals.list
rm -f ~/.cache/xdg-terminal-exec
```

## 验证

```bash
xdg-terminal-exec --print-id
xdg-terminal-exec --print-cmd --dir="$HOME"
```

预期：

- `xdg-terminal-exec --print-id` 返回 `com.mitchellh.ghostty.desktop`
- `xdg-terminal-exec --print-cmd --dir="$HOME"` 解析到 `/usr/bin/ghostty`

## 相关

如果你还想让 Nautilus 的 `Open in Terminal` 也打开 `ghostty`，以及给右键菜单增加 `Copy Path`，请看单独的 extra：`extras/nautilus-enhancements/README.md`。
