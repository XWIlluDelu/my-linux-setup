# ghostty-default-terminal

把 `ghostty` 设为 GNOME 下由 `xdg-terminal-exec` 解析出来的默认终端。

## 设置内容

- 写入 `~/.config/gnome-xdg-terminals.list`
- 写入 `~/.config/xdg-terminals.list`
- 两个文件都使用相同顺序：

```text
com.mitchellh.ghostty.desktop
org.gnome.Terminal.desktop
```

- 清理 `~/.cache/xdg-terminal-exec`

这样 `xdg-terminal-exec` 会优先选择 `Ghostty`，并保留 `GNOME Terminal` 作为回退。

## 范围

- 这里只处理 GNOME 下由 `xdg-terminal-exec` 解析的默认终端
- 不处理文件浏览器右键菜单
- 不处理 Debian/Ubuntu 的 `x-terminal-emulator`

## 步骤

确认 `ghostty` 的 desktop file 存在：

```bash
ls /usr/share/applications/com.mitchellh.ghostty.desktop
```

备份旧配置并写入用户级优先列表：

```bash
mkdir -p ~/.config
cp -a ~/.config/xdg-terminals.list ~/.config/xdg-terminals.list.bak.$(date +%Y%m%d-%H%M%S) 2>/dev/null || true
cp -a ~/.config/gnome-xdg-terminals.list ~/.config/gnome-xdg-terminals.list.bak.$(date +%Y%m%d-%H%M%S) 2>/dev/null || true

printf '%s\n' \
  'com.mitchellh.ghostty.desktop' \
  'org.gnome.Terminal.desktop' \
  > ~/.config/gnome-xdg-terminals.list

printf '%s\n' \
  'com.mitchellh.ghostty.desktop' \
  'org.gnome.Terminal.desktop' \
  > ~/.config/xdg-terminals.list

rm -f ~/.cache/xdg-terminal-exec
```

## 验证

```bash
xdg-terminal-exec --print-id
xdg-terminal-exec --print-cmd --dir="$HOME"
```

预期：

- `xdg-terminal-exec --print-id` 返回 `com.mitchellh.ghostty.desktop`
- `xdg-terminal-exec --print-cmd --dir="$HOME"` 解析到：

```text
/usr/bin/ghostty
--gtk-single-instance=true
--working-directory=/home/your-user
```

## 相关

如果你还想让 Nautilus 的 `Open in Terminal` 也打开 `ghostty`，以及给右键菜单增加 `Copy Path`，请看单独的 extra：`extras/nautilus-enhancements/README.md`。
