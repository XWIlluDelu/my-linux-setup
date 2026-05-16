# ghostty-default-terminal

记录 GNOME `xdg-terminal-exec` 默认终端的用户级优先列表。本机当前保留 GNOME Terminal 优先，Ghostty 作为回退。

## 范围

- 写用户级 `~/.config/gnome-xdg-terminals.list`
- 写用户级 `~/.config/xdg-terminals.list`
- 清理 `~/.cache/xdg-terminal-exec`
- 不处理 Nautilus 右键菜单
- 不处理 Debian/Ubuntu `x-terminal-emulator`

## 设置

确认 desktop file 存在：

```bash
ls /usr/share/applications/com.mitchellh.ghostty.desktop
```

写入优先列表：

```bash
mkdir -p ~/.config
cp -a ~/.config/xdg-terminals.list ~/.config/xdg-terminals.list.bak.$(date +%Y%m%d-%H%M%S) 2>/dev/null || true
cp -a ~/.config/gnome-xdg-terminals.list ~/.config/gnome-xdg-terminals.list.bak.$(date +%Y%m%d-%H%M%S) 2>/dev/null || true

printf '%s\n' \
  'org.gnome.Terminal.desktop' \
  'com.mitchellh.ghostty.desktop' \
  > ~/.config/gnome-xdg-terminals.list

printf '%s\n' \
  'org.gnome.Terminal.desktop' \
  'com.mitchellh.ghostty.desktop' \
  > ~/.config/xdg-terminals.list

rm -f ~/.cache/xdg-terminal-exec
```

## 验证

```bash
xdg-terminal-exec --print-id
xdg-terminal-exec --print-cmd --dir="$HOME"
```

预期：

- 本机当前 `--print-id` 返回 `org.gnome.Terminal.desktop`
- `--print-cmd` 解析到 `gnome-terminal --working-directory <dir>`

Nautilus 右键菜单增强见 [`../nautilus-enhancements/README.md`](../nautilus-enhancements/README.md)。
