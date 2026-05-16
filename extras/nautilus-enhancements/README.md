# nautilus-enhancements

Nautilus 增强记录：

- `Open in Terminal` 当前由 `/usr/share/nautilus-python/extensions/ghostty.py` 处理
- 右键菜单增加 `Copy Path`

## 当前本机状态

| 项 | 状态 |
|---|---|
| `python3-nautilus` | 已安装 |
| `nautilus-extension-gnome-terminal` | 未安装 |
| `nautilus-extension-any-terminal` schema | 当前不存在 |
| Ghostty terminal extension | `/usr/share/nautilus-python/extensions/ghostty.py` |
| Copy Path extension | `/usr/local/share/nautilus-python/extensions/nautilus-copy-path.py` + 配套目录 |

## Copy Path 系统级安装

`nautilus-copy-path` 没有 Debian 包。安装到 `/usr/local/share/nautilus-python/extensions`，不走 `pip`，也不混入 dpkg 管理的 `/usr/share/nautilus-python/extensions`。

```bash
rm -rf /tmp/nautilus-copy-path-src /tmp/nautilus-copy-path-system
git clone --depth 1 https://github.com/chr314/nautilus-copy-path.git /tmp/nautilus-copy-path-src
mkdir -p /tmp/nautilus-copy-path-system/extensions/nautilus-copy-path
cp /tmp/nautilus-copy-path-src/nautilus-copy-path.py /tmp/nautilus-copy-path-system/extensions/
cp /tmp/nautilus-copy-path-src/nautilus_copy_path.py /tmp/nautilus-copy-path-src/translation.py /tmp/nautilus-copy-path-src/config.json /tmp/nautilus-copy-path-system/extensions/nautilus-copy-path/
cp -r /tmp/nautilus-copy-path-src/translations /tmp/nautilus-copy-path-system/extensions/nautilus-copy-path/
```

只保留 `Copy Path`：

```bash
cat > /tmp/nautilus-copy-path-system/extensions/nautilus-copy-path/config.json <<'EOF'
{
  "items": {"path": true, "uri": false, "name": false, "content": false},
  "selections": {"clipboard": true, "primary": false},
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

安装：

```bash
sudo mkdir -p /usr/local/share/nautilus-python/extensions
sudo rm -rf /usr/local/share/nautilus-python/extensions/nautilus-copy-path /usr/local/share/nautilus-python/extensions/nautilus-copy-path.py
sudo cp -r /tmp/nautilus-copy-path-system/extensions/nautilus-copy-path /usr/local/share/nautilus-python/extensions/
sudo cp /tmp/nautilus-copy-path-system/extensions/nautilus-copy-path.py /usr/local/share/nautilus-python/extensions/
nautilus -q
```

## 验证

```bash
find /usr/share/nautilus-python/extensions /usr/local/share/nautilus-python/extensions -maxdepth 2 -type f | sort
nautilus -q
```

预期：Nautilus 右键菜单出现 `Copy Path`；`Open in Terminal` 由已安装的 Ghostty Nautilus Python 扩展提供。
