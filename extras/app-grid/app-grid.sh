#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
source "$ROOT_DIR/lib/common.sh"

MODE=""
FOLDERS_JSON=""

usage() {
  cat <<'EOF'
Manage GNOME application grid folders and orphan icons.

Usage:
  app-grid.sh --analyze
  app-grid.sh --apply --folders-json FILE

Modes:
  --analyze          Output current Dock, folders, and orphan icons as JSON (stdout)
  --apply            Apply folder definitions from a JSON file to gsettings
  --folders-json F   Path to the JSON file containing folder definitions (required for --apply)

Notes:
  - Does not require sudo (gsettings operates on user-level dconf).
  - --apply creates a backup script in /tmp before making changes.
  - See AGENT-INSTRUCTIONS.md for JSON format and agent workflow.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --analyze)
      MODE="analyze"
      ;;
    --apply)
      MODE="apply"
      ;;
    --folders-json)
      [[ $# -ge 2 ]] || die "--folders-json requires a file path"
      FOLDERS_JSON="$2"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
  shift
done

if [[ -z "$MODE" ]]; then
  usage
  exit 0
fi

ensure_command gsettings
ensure_command python3

# === Analyze Mode ===

if [[ "$MODE" == "analyze" ]]; then
  info "Analyzing GNOME application grid..." >&2
  python3 << 'PYEOF'
import json, os, subprocess, sys

def gsettings_get(schema, key, path=None):
    cmd = ["gsettings", "get"]
    if path:
        cmd.append(f"{schema}:{path}")
        cmd.append(key)
    else:
        cmd.extend([schema, key])
    try:
        return subprocess.check_output(cmd, stderr=subprocess.DEVNULL, text=True).strip()
    except subprocess.CalledProcessError:
        return ""

def parse_gsettings_array(raw):
    if not raw or raw == "@as []":
        return []
    items = []
    for item in raw.strip("[]").split(","):
        item = item.strip().strip("'")
        if item:
            items.append(item)
    return items

def scan_visible_desktop_files(excluded):
    search_paths = [
        "/usr/share/applications",
        os.path.expanduser("~/.local/share/applications"),
        "/var/lib/snapd/desktop/applications",
        os.path.expanduser("~/.local/share/flatpak/exports/share/applications"),
        "/var/lib/flatpak/exports/share/applications",
    ]
    desktop_files = {}
    for path in search_paths:
        if os.path.isdir(path):
            for f in os.listdir(path):
                if f.endswith(".desktop"):
                    desktop_files[f] = os.path.join(path, f)

    visible = []
    for desktop_id, filepath in sorted(desktop_files.items()):
        if desktop_id in excluded:
            continue
        try:
            with open(filepath, "r", errors="replace") as fh:
                content = fh.read()
            in_entry = False
            props = {}
            for line in content.splitlines():
                line = line.strip()
                if line == "[Desktop Entry]":
                    in_entry = True
                    continue
                if line.startswith("[") and line.endswith("]"):
                    in_entry = False
                    continue
                if in_entry and "=" in line:
                    k, _, v = line.partition("=")
                    props[k.strip()] = v.strip()

            if props.get("Type", "") not in ("", "Application"):
                continue
            if props.get("NoDisplay", "false").lower() == "true":
                continue
            if props.get("Hidden", "false").lower() == "true":
                continue

            osi = props.get("OnlyShowIn", "")
            if osi:
                tokens = [x.strip().rstrip(";") for x in osi.replace(";", ",").split(",") if x.strip()]
                if not any(x in ("GNOME", "Unity", "X-Cinnamon") for x in tokens):
                    continue

            nsi = props.get("NotShowIn", "")
            if nsi:
                tokens = [x.strip().rstrip(";") for x in nsi.replace(";", ",").split(",") if x.strip()]
                if "GNOME" in tokens:
                    continue

            te = props.get("TryExec", "")
            if te:
                expanded = os.path.expanduser(te)
                if not os.path.isfile(expanded) and not any(
                    os.path.isfile(os.path.join(p, te))
                    for p in os.environ.get("PATH", "").split(":")
                ):
                    continue

            name = props.get("Name", desktop_id.replace(".desktop", ""))
            visible.append({"name": name, "desktop_id": desktop_id})
        except Exception:
            pass
    return visible

# Dock
dock_raw = gsettings_get("org.gnome.shell", "favorite-apps")
dock_apps = set(parse_gsettings_array(dock_raw))

# Folders
folder_children_raw = gsettings_get("org.gnome.desktop.app-folders", "folder-children")
folder_ids = parse_gsettings_array(folder_children_raw)

folders = {}
all_folder_apps = set()
for fid in folder_ids:
    path = f"/org/gnome/desktop/app-folders/folders/{fid}/"
    name = gsettings_get("org.gnome.desktop.app-folders.folder", "name", path)
    name = name.strip("'")
    apps_raw = gsettings_get("org.gnome.desktop.app-folders.folder", "apps", path)
    apps = parse_gsettings_array(apps_raw)
    folders[fid] = {"name": name, "apps": apps}
    all_folder_apps.update(apps)

# Orphans
excluded = dock_apps | all_folder_apps
orphans = scan_visible_desktop_files(excluded)

result = {
    "dock": sorted(dock_apps),
    "folders": folders,
    "orphans": orphans,
}

json.dump(result, sys.stdout, indent=2, ensure_ascii=False)
print()
PYEOF
  exit 0
fi

# === Apply Mode ===

if [[ "$MODE" == "apply" ]]; then
  if [[ -z "$FOLDERS_JSON" ]]; then
    die "--apply requires --folders-json FILE"
  fi
  if [[ ! -f "$FOLDERS_JSON" ]]; then
    die "Folders JSON file not found: $FOLDERS_JSON"
  fi

  info "Creating backup..."
  BACKUP_FILE="/tmp/app-grid-backup-$(date +%Y%m%d%H%M%S).sh"

  python3 - "$BACKUP_FILE" << 'PYEOF'
import os, subprocess, sys

backup_file = sys.argv[1]

def gsettings_get(schema, key, path=None):
    cmd = ["gsettings", "get"]
    if path:
        cmd.append(f"{schema}:{path}")
        cmd.append(key)
    else:
        cmd.extend([schema, key])
    try:
        return subprocess.check_output(cmd, stderr=subprocess.DEVNULL, text=True).strip()
    except subprocess.CalledProcessError:
        return ""

def parse_gsettings_array(raw):
    if not raw or raw == "@as []":
        return []
    items = []
    for item in raw.strip("[]").split(","):
        item = item.strip().strip("'")
        if item:
            items.append(item)
    return items

lines = [
    "#!/usr/bin/env bash",
    "# Auto-generated backup — run this script to undo app-grid changes",
    f"# Generated at: {subprocess.check_output(['date'], text=True).strip()}",
    "",
]

fc = gsettings_get("org.gnome.desktop.app-folders", "folder-children")
lines.append(f'gsettings set org.gnome.desktop.app-folders folder-children "{fc}"')

for fid in parse_gsettings_array(fc):
    path = f"/org/gnome/desktop/app-folders/folders/{fid}/"
    name = gsettings_get("org.gnome.desktop.app-folders.folder", "name", path)
    apps = gsettings_get("org.gnome.desktop.app-folders.folder", "apps", path)
    lines.append(f'gsettings set org.gnome.desktop.app-folders.folder:/org/gnome/desktop/app-folders/folders/{fid}/ name "{name}"')
    lines.append(f'gsettings set org.gnome.desktop.app-folders.folder:/org/gnome/desktop/app-folders/folders/{fid}/ apps "{apps}"')

layout = gsettings_get("org.gnome.shell", "app-picker-layout")
lines.append(f'gsettings set org.gnome.shell app-picker-layout "{layout}"')

with open(backup_file, "w") as f:
    f.write("\n".join(lines) + "\n")
os.chmod(backup_file, 0o755)
PYEOF

  info "Backup saved to $BACKUP_FILE"

  info "Applying folder definitions from $FOLDERS_JSON..."
  python3 - "$FOLDERS_JSON" << 'PYEOF'
import json, os, subprocess, sys

json_path = sys.argv[1]
with open(json_path) as f:
    data = json.load(f)

folders_def = data.get("folders", [])
if not folders_def:
    print("[WARN] No folders defined in JSON; nothing to apply.", file=sys.stderr)
    sys.exit(0)

DESKTOP_DIRS = [
    "/usr/share/applications",
    os.path.expanduser("~/.local/share/applications"),
    "/var/lib/snapd/desktop/applications",
    os.path.expanduser("~/.local/share/flatpak/exports/share/applications"),
    "/var/lib/flatpak/exports/share/applications",
]

def desktop_exists(desktop_id):
    return any(os.path.isfile(os.path.join(d, desktop_id)) for d in DESKTOP_DIRS)

def gsettings_set(schema, key, value, path=None):
    cmd = ["gsettings", "set"]
    if path:
        cmd.append(f"{schema}:{path}")
    else:
        cmd.append(schema)
    cmd.extend([key, value])
    subprocess.check_call(cmd, stderr=subprocess.DEVNULL)

# 1. Set folder-children
folder_ids = [f["id"] for f in folders_def]
children_str = "[" + ", ".join(f"'{fid}'" for fid in folder_ids) + "]"
gsettings_set("org.gnome.desktop.app-folders", "folder-children", children_str)

# 2. Configure each folder
for folder in folders_def:
    fid = folder["id"]
    name = folder.get("name", fid)
    apps = folder.get("apps", [])
    path = f"/org/gnome/desktop/app-folders/folders/{fid}/"

    existing = [a for a in apps if desktop_exists(a)]
    skipped = [a for a in apps if not desktop_exists(a)]

    for s in skipped:
        print(f"  [skip] {s} (not found)", file=sys.stderr)

    apps_str = "[" + ", ".join(f"'{a}'" for a in existing) + "]"
    gsettings_set("org.gnome.desktop.app-folders.folder", "name", f"'{name}'", path)
    gsettings_set("org.gnome.desktop.app-folders.folder", "apps", apps_str, path)
    print(f"  [done] {fid}: {len(existing)} apps", file=sys.stderr)

# 3. Set layout order
layout_entries = ", ".join(
    f"'{fid}': <{{'position': <{i}>}}>"
    for i, fid in enumerate(folder_ids)
)
layout_str = f"[{{{layout_entries}}}]"
gsettings_set("org.gnome.shell", "app-picker-layout", layout_str)

# 4. Report orphans
def gsettings_get(schema, key, path=None):
    cmd = ["gsettings", "get"]
    if path:
        cmd.append(f"{schema}:{path}")
        cmd.append(key)
    else:
        cmd.extend([schema, key])
    try:
        return subprocess.check_output(cmd, stderr=subprocess.DEVNULL, text=True).strip()
    except subprocess.CalledProcessError:
        return ""

def parse_gsettings_array(raw):
    if not raw or raw == "@as []":
        return []
    return [item.strip().strip("'") for item in raw.strip("[]").split(",") if item.strip()]

dock_apps = set(parse_gsettings_array(
    gsettings_get("org.gnome.shell", "favorite-apps")
))
all_folder_apps = set()
for fid in folder_ids:
    p = f"/org/gnome/desktop/app-folders/folders/{fid}/"
    apps_raw = gsettings_get("org.gnome.desktop.app-folders.folder", "apps", p)
    all_folder_apps.update(parse_gsettings_array(apps_raw))

excluded = dock_apps | all_folder_apps
orphan_count = 0
for d in DESKTOP_DIRS:
    if not os.path.isdir(d):
        continue
    for f in os.listdir(d):
        if not f.endswith(".desktop") or f in excluded:
            continue
        fp = os.path.join(d, f)
        try:
            with open(fp, "r", errors="replace") as fh:
                content = fh.read()
            in_entry = False; props = {}
            for line in content.splitlines():
                line = line.strip()
                if line == "[Desktop Entry]": in_entry = True; continue
                if line.startswith("[") and line.endswith("]"): in_entry = False; continue
                if in_entry and "=" in line:
                    k, _, v = line.partition("="); props[k.strip()] = v.strip()
            if props.get("Type", "") not in ("", "Application"): continue
            if props.get("NoDisplay", "false").lower() == "true": continue
            if props.get("Hidden", "false").lower() == "true": continue
            orphan_count += 1
        except Exception:
            pass

print(f"\n[INFO] Remaining orphan icons: {orphan_count}", file=sys.stderr)
PYEOF

  info "App grid updated. Undo: bash $BACKUP_FILE"
  exit 0
fi
