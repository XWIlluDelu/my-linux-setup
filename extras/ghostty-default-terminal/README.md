# ghostty-default-terminal

Records the user-level priority list for the GNOME `xdg-terminal-exec` default terminal. Currently keeps GNOME Terminal first, Ghostty as fallback.

## Scope

- Write user-level `~/.config/gnome-xdg-terminals.list`
- Write user-level `~/.config/xdg-terminals.list`
- Clear `~/.cache/xdg-terminal-exec`
- Does not touch the Nautilus context menu
- Does not touch the Debian/Ubuntu `x-terminal-emulator`

## Setup

Confirm the desktop file exists:

```bash
ls /usr/share/applications/com.mitchellh.ghostty.desktop
```

Write the priority list:

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

## Verification

```bash
xdg-terminal-exec --print-id
xdg-terminal-exec --print-cmd --dir="$HOME"
```

Expected:

- Locally, `--print-id` returns `org.gnome.Terminal.desktop`
- `--print-cmd` resolves to `gnome-terminal --working-directory <dir>`

For Nautilus context menu enhancements see [`../nautilus-enhancements/README.md`](../nautilus-enhancements/README.md).
