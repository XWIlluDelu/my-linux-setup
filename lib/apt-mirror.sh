#!/usr/bin/env bash

# APT source transformation used by the mirror maintenance command.
# Requires as_root from common.sh because source files can be root-readable only.

render_apt_mirror_candidate() {
  local source_file candidate_file os_id target_host
  source_file="$1"
  candidate_file="$2"
  os_id="$3"
  target_host="$4"

  as_root python3 - "$source_file" "$candidate_file" "$os_id" "$target_host" <<'PY'
import pathlib
import re
import sys

source = pathlib.Path(sys.argv[1])
candidate = pathlib.Path(sys.argv[2])
os_id = sys.argv[3]
target_host = sys.argv[4]
text = source.read_text()

if os_id == "ubuntu":
    pattern = re.compile(r'https?://([^/\s]+)/ubuntu/?')
    security_host = "security.ubuntu.com"
    suffix = "ubuntu"
elif os_id == "debian":
    pattern = re.compile(r'https?://([^/\s]+)/debian/?')
    security_host = "security.debian.org"
    suffix = "debian"
else:
    raise SystemExit(2)

def replace(match: re.Match[str]) -> str:
    if match.group(1).lower() == security_host:
        return match.group(0)
    return f"https://{target_host}/{suffix}/"

updated = pattern.sub(replace, text)
if updated == text:
    raise SystemExit("no distribution mirror URL was replaced")
candidate.write_text(updated)
PY
}
