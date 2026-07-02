# nautilus-enhancements

Nautilus enhancement notes:

- `Open in Terminal` is currently handled by `/usr/share/nautilus-python/extensions/ghostty.py`
- Context menu gains a `Copy Path` entry

## Current local state

| Item | State |
|---|---|
| `python3-nautilus` | installed |
| `nautilus-extension-gnome-terminal` | not installed |
| `nautilus-extension-any-terminal` schema | not present |
| Ghostty terminal extension | `/usr/share/nautilus-python/extensions/ghostty.py` |
| Copy Path extension | `/usr/local/share/nautilus-python/extensions/nautilus-copy-path.py` + supporting directory |

## Copy Path system-level install

`nautilus-copy-path` has no Debian package. Install it into `/usr/local/share/nautilus-python/extensions`, not via `pip`, and keep it out of the dpkg-managed `/usr/share/nautilus-python/extensions`.

```bash
rm -rf /tmp/nautilus-copy-path-src /tmp/nautilus-copy-path-system
git clone --depth 1 https://github.com/chr314/nautilus-copy-path.git /tmp/nautilus-copy-path-src
mkdir -p /tmp/nautilus-copy-path-system/extensions/nautilus-copy-path
cp /tmp/nautilus-copy-path-src/nautilus-copy-path.py /tmp/nautilus-copy-path-system/extensions/
cp /tmp/nautilus-copy-path-src/nautilus_copy_path.py /tmp/nautilus-copy-path-src/translation.py /tmp/nautilus-copy-path-src/config.json /tmp/nautilus-copy-path-system/extensions/nautilus-copy-path/
cp -r /tmp/nautilus-copy-path-src/translations /tmp/nautilus-copy-path-system/extensions/nautilus-copy-path/
```

Keep only `Copy Path`:

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

Install:

```bash
sudo mkdir -p /usr/local/share/nautilus-python/extensions
sudo rm -rf /usr/local/share/nautilus-python/extensions/nautilus-copy-path /usr/local/share/nautilus-python/extensions/nautilus-copy-path.py
sudo cp -r /tmp/nautilus-copy-path-system/extensions/nautilus-copy-path /usr/local/share/nautilus-python/extensions/
sudo cp /tmp/nautilus-copy-path-system/extensions/nautilus-copy-path.py /usr/local/share/nautilus-python/extensions/
nautilus -q
```

## Verification

```bash
find /usr/share/nautilus-python/extensions /usr/local/share/nautilus-python/extensions -maxdepth 2 -type f | sort
nautilus -q
```

Expected: the Nautilus context menu shows `Copy Path`; `Open in Terminal` is provided by the installed Ghostty Nautilus Python extension.
