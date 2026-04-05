# nautilus-enhancements

给 Nautilus 增加两个增强：

- `Open in Terminal` 使用 `ghostty`
- 右键菜单增加 `Copy Path`

这里只保留当前验证过的正确方案。

## 1. 用官方扩展接管 Open in Terminal

不要使用旧的 `nautilus-extension-gnome-terminal`，它会把菜单绑死到 `gnome-terminal`。

先移除旧扩展：

```bash
sudo apt remove -y nautilus-extension-gnome-terminal
```

下载并安装官方 `nautilus-extension-any-terminal`：

```bash
wget -O /tmp/nautilus-extension-any-terminal.deb \
  "https://github.com/Stunkymonkey/nautilus-open-any-terminal/releases/download/0.8.1/nautilus-extension-any-terminal_0.8.1-1_all.deb"
sudo apt install -y python3-nautilus /tmp/nautilus-extension-any-terminal.deb
```

把它显式设为 `ghostty`：

```bash
gsettings set com.github.stunkymonkey.nautilus-open-any-terminal terminal ghostty
nautilus -q
```

说明：

- `nautilus -q` 返回 `255` 通常是正常现象
- `Adwaita-WARNING` 一般只是样式资源警告，不影响功能

## 2. 系统级安装 Copy Path

`nautilus-copy-path` 没有现成 Debian 包。这里采用系统级安装到 `/usr/local/share/nautilus-python/extensions`，避免走 `pip`，也避免和 dpkg 管理的 `/usr/share/nautilus-python/extensions` 混在一起。

先准备文件：

```bash
rm -rf /tmp/nautilus-copy-path-src /tmp/nautilus-copy-path-system
git clone --depth 1 https://github.com/chr314/nautilus-copy-path.git /tmp/nautilus-copy-path-src
mkdir -p /tmp/nautilus-copy-path-system/extensions/nautilus-copy-path
cp /tmp/nautilus-copy-path-src/nautilus-copy-path.py /tmp/nautilus-copy-path-system/extensions/
cp /tmp/nautilus-copy-path-src/nautilus_copy_path.py /tmp/nautilus-copy-path-src/translation.py /tmp/nautilus-copy-path-src/config.json /tmp/nautilus-copy-path-system/extensions/nautilus-copy-path/
cp -r /tmp/nautilus-copy-path-src/translations /tmp/nautilus-copy-path-system/extensions/nautilus-copy-path/
```

把配置改成只保留 `Copy Path`：

```bash
cat > /tmp/nautilus-copy-path-system/extensions/nautilus-copy-path/config.json <<'EOF'
{
  "items": {
    "path": true,
    "uri": false,
    "name": false,
    "content": false
  },
  "selections": {
    "clipboard": true,
    "primary": false
  },
  "shortcuts": {
    "path": "<Ctrl><Shift>C",
    "uri": "<Ctrl><Shift>U",
    "name": "<Ctrl><Shift>D",
    "content": "<Ctrl><Shift>G"
  },
  "language": "auto",
  "separator": ", ",
  "escape_value_items": false,
  "escape_value": false,
  "name_ignore_extension": false
}
EOF
```

安装到系统扩展目录：

```bash
sudo mkdir -p /usr/local/share/nautilus-python/extensions
sudo rm -rf /usr/local/share/nautilus-python/extensions/nautilus-copy-path /usr/local/share/nautilus-python/extensions/nautilus-copy-path.py
sudo cp -r /tmp/nautilus-copy-path-system/extensions/nautilus-copy-path /usr/local/share/nautilus-python/extensions/
sudo cp /tmp/nautilus-copy-path-system/extensions/nautilus-copy-path.py /usr/local/share/nautilus-python/extensions/
nautilus -q
```

## 验证

```bash
gsettings get com.github.stunkymonkey.nautilus-open-any-terminal terminal
```

预期：

- `gsettings get ... terminal` 返回 `'ghostty'`
- Nautilus 右键菜单里的 `Open in Terminal` 打开 `ghostty`
- Nautilus 右键菜单出现 `Copy Path`
