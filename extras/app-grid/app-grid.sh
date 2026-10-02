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
import ast, json, os, subprocess, sys

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
    return ast.literal_eval(raw) if raw and raw != "@as []" else []

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
    name = ast.literal_eval(name)
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

  info "Applying folder definitions from $FOLDERS_JSON..."
  python3 - "$FOLDERS_JSON" << 'PYEOF'
import ast, json, os, subprocess, sys

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

# Prepare the whole definition before changing settings. JSON strings and
# string arrays are also valid GVariant text, including quotes and backslashes.
planned_folders = []
for folder in folders_def:
    fid = folder["id"]
    name = folder.get("name", fid)
    apps = folder.get("apps", [])
    if not isinstance(fid, str) or not fid or "/" in fid:
        raise ValueError("Folder id must be a nonempty path component")
    if not isinstance(name, str):
        raise ValueError(f"Folder {fid}: name must be a string")
    if not isinstance(apps, list) or not all(isinstance(app, str) for app in apps):
        raise ValueError(f"Folder {fid}: apps must be a list of desktop IDs")

    existing = []
    for app in apps:
        if desktop_exists(app):
            existing.append(app)
        else:
            print(f"  [skip] {app} (not found)", file=sys.stderr)
    planned_folders.append((fid, name, existing))

folder_ids = [fid for fid, _, _ in planned_folders]
layout_entries = ", ".join(
    f"{json.dumps(fid, ensure_ascii=False)}: <{{'position': <{i}>}}>"
    for i, fid in enumerate(folder_ids)
)
layout_str = f"[{{{layout_entries}}}]"

# Publish folder membership and layout after configuring the folders.
for fid, name, apps in planned_folders:
    path = f"/org/gnome/desktop/app-folders/folders/{fid}/"
    gsettings_set("org.gnome.desktop.app-folders.folder", "name", json.dumps(name, ensure_ascii=False), path)
    gsettings_set("org.gnome.desktop.app-folders.folder", "apps", json.dumps(apps, ensure_ascii=False), path)
    print(f"  [done] {fid}: {len(apps)} apps", file=sys.stderr)

gsettings_set("org.gnome.desktop.app-folders", "folder-children", json.dumps(folder_ids, ensure_ascii=False))
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
    return ast.literal_eval(raw) if raw and raw != "@as []" else []

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

  info "App grid updated."
  exit 0
fi
