# GNOME app grid organization — Agent instructions

> This file is for AI agents and guides automated organization of orphan icons in the GNOME app grid.

## Workflow

1. **Analyze**: run `bash app-grid.sh --analyze` to get a JSON list of the current Dock, folders, and orphan icons
2. **Plan**: based on the user preferences below and the analysis, generate a classification JSON file
3. **Apply**: run `bash app-grid.sh --apply --folders-json /tmp/folders.json`

## Analysis output format

`--analyze` prints JSON to stdout (info logs go to stderr):

```json
{
  "dock": ["org.gnome.Nautilus.desktop", "firefox.desktop", ...],
  "folders": {
    "System": {
      "name": "System",
      "apps": ["org.gnome.Settings.desktop", ...]
    }
  },
  "orphans": [
    {"name": "Calculator", "desktop_id": "org.gnome.Calculator.desktop"},
    ...
  ]
}
```

## Classification JSON format

Accepted by `--apply --folders-json FILE`:

```json
{
  "folders": [
    {
      "id": "System",
      "name": "System",
      "apps": [
        "org.gnome.Settings.desktop",
        "org.gnome.tweaks.desktop",
        "org.gnome.DiskUtility.desktop"
      ]
    },
    {
      "id": "Utilities",
      "name": "Utilities",
      "apps": ["org.gnome.Calculator.desktop", "org.gnome.TextEditor.desktop"]
    }
  ]
}
```

- Non-existent `.desktop` files are skipped automatically
- After applying, the remaining orphan count is printed

## User classification preferences

The user's habitual folder classifications (the agent should generate JSON from these):

### System — system settings / drivers / updates / security

- Network connection editor, disks utility, system monitor, system settings, GNOME Tweaks
- Software sources, driver manager, update manager, language support, extension manager
- Power statistics, key management (Seahorse), system log, input method config

### Utilities — everyday small tools

- Calculator, character map, clock, text editor, font viewer
- Image viewer (Loupe), document viewer (Papers)
- Help (Yelp), htop, vim, mpv, info

### Online — online / network tools

- WeChat, Clash Verge, remote-connection tools
- Other desktop apps that lean toward "online service" rather than "system settings" go here first

### Office — documents / knowledge management

- Obsidian, Zotero, the LibreOffice suite
- Other notes, writing, reading, and office tools go here first

### NVIDIA — GPU development and debugging tools

- nvidia-settings, Nsight Compute, Nsight Systems, NVVP
- Any other NVIDIA/CUDA-related `.desktop` files

### Fcitx — input method related

- Fcitx5 main program, config tool, migration tool, keyboard layout viewer

### Media — media playback

- mpv
- Other audio/video apps that are players rather than editors go here first

## Additional preferences

- Classifications should follow the apps currently installed on this machine; do not apply a fixed template rigidly. Folders may be omitted when no matching app exists.
- The user prefers to keep `simple-scan`, so it should go into `Utilities` first.
- The user prefers to keep `LibreOffice`, and group it with `Obsidian` and `Zotero` under `Office` first.
- The user prefers the newer `papers` as document viewer; only treat `evince` as removable when both `evince` and `papers` exist. If only one remains, keep it.
- The user prefers to minimize low-value default applets; if `xterm`, `uxterm`, `Text Editor`, or `Calculator` still appear, they are low-priority keepers and should not take prominent positions.
- If `WeChat`, `Clash Verge`, and remote-connection apps coexist, put them in `Online` first, not `System`.
- The user prefers not to keep `Showtime`; if it still exists temporarily, it may go into `Media`, but cleanup scripts should remove it by default.

## Notes

- Both analysis and apply **do not need sudo** (gsettings operates on user-level dconf)
- After installing or uninstalling apps, the classification list may be stale; rerun analysis
- Suggested folder order: System → Utilities → Online → Office → NVIDIA → Fcitx → Media → remaining orphans
