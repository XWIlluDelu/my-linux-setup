#!/usr/bin/env bash

# Verified downloads and GitHub release discovery.

declare -a MIRROR_PREFIXES=()

download_url_with_speed_guard() {
  local url target_path expected_sha256 tmp_path actual_sha256
  url="$1"
  target_path="$2"
  expected_sha256="${3:-}"

  ensure_command curl
  mkdir -p "$(dirname "$target_path")"

  if [[ -f "$target_path" ]]; then
    if [[ -z "$expected_sha256" ]]; then
      info "No digest available for $url; re-downloading instead of trusting the cached file."
      rm -f "$target_path"
    else
      actual_sha256="$(sha256sum "$target_path" | awk '{print $1}')"
      if [[ "$actual_sha256" == "$expected_sha256" ]]; then
        info "Using existing verified file: $target_path"
        return 0
      fi

      warn "Existing file failed digest verification, re-downloading: $target_path"
      rm -f "$target_path"
    fi
  fi

  tmp_path="${target_path}.part"
  rm -f "$tmp_path"

  info "Downloading from: $url"
  if ! curl \
    -fL \
    --progress-bar \
    --connect-timeout "${DOWNLOAD_CONNECT_TIMEOUT:-5}" \
    --speed-limit "${DOWNLOAD_SPEED_LIMIT:-204800}" \
    --speed-time "${DOWNLOAD_SPEED_TIME:-8}" \
    -o "$tmp_path" \
    "$url"; then
    rm -f "$tmp_path"
    return 1
  fi

  if [[ -n "$expected_sha256" ]]; then
    ensure_command sha256sum
    actual_sha256="$(sha256sum "$tmp_path" | awk '{print $1}')"
    if [[ "$actual_sha256" != "$expected_sha256" ]]; then
      rm -f "$tmp_path"
      warn "Digest mismatch for $url"
      return 1
    fi
  fi

  mv "$tmp_path" "$target_path"
  info "Saved to $target_path"
}
github_release_api_get() {
  local url
  url="$1"

  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    curl -fsSL \
      -H 'Accept: application/vnd.github+json' \
      -H 'X-GitHub-Api-Version: 2022-11-28' \
      -H 'User-Agent: linux-setup' \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      "$url"
  else
    curl -fsSL \
      -H 'Accept: application/vnd.github+json' \
      -H 'X-GitHub-Api-Version: 2022-11-28' \
      -H 'User-Agent: linux-setup' \
      "$url"
  fi
}
github_release_parse_latest() {
  local repo asset_regex tag_strip_prefix assignments
  repo="$1"
  asset_regex="$2"
  tag_strip_prefix="${3:-}"

  ensure_command curl
  ensure_command python3

  if assignments="$(
    github_release_api_get "https://api.github.com/repos/${repo}/releases/latest" \
      | python3 -c '
import json
import re
import shlex
import sys

asset_regex = re.compile(sys.argv[1])
tag_strip_prefix = sys.argv[2]
data = json.load(sys.stdin)

asset = None
for current in data.get("assets", []):
    name = current.get("name", "")
    url = current.get("browser_download_url", "")
    if asset_regex.search(name) or asset_regex.search(url):
        asset = current
        break

if asset is None:
    raise SystemExit(2)

tag = data.get("tag_name", "")
version = tag[len(tag_strip_prefix):] if tag_strip_prefix and tag.startswith(tag_strip_prefix) else tag
digest = asset.get("digest", "")
if digest.startswith("sha256:"):
    digest = digest.split(":", 1)[1]

fields = {
    "GITHUB_RELEASE_TAG": tag,
    "GITHUB_RELEASE_VERSION": version,
    "GITHUB_RELEASE_URL": data.get("html_url", ""),
    "GITHUB_RELEASE_PUBLISHED_AT": data.get("published_at", ""),
    "GITHUB_ASSET_NAME": asset.get("name", ""),
    "GITHUB_ASSET_URL": asset.get("browser_download_url", ""),
    "GITHUB_ASSET_DIGEST": digest,
}

for key, value in fields.items():
    print(f"{key}={shlex.quote(value)}")
' "$asset_regex" "$tag_strip_prefix"
  )"; then
    :
  else
    if ! assignments="$(
      python3 - "$repo" "$asset_regex" "$tag_strip_prefix" <<'PY'
import html
import re
import shlex
import subprocess
import sys

repo = sys.argv[1]
asset_regex = re.compile(sys.argv[2])
tag_strip_prefix = sys.argv[3]
latest_url = f"https://github.com/{repo}/releases/latest"

def curl(*args):
    return subprocess.check_output(
        ["curl", "-fsSL", "-A", "linux-setup", *args],
        universal_newlines=True,
    )

release_url = curl("-o", "/dev/null", "-w", "%{url_effective}", latest_url).strip()
if not release_url:
    raise SystemExit(1)

tag = release_url.rstrip("/").rsplit("/", 1)[-1]
html_doc = curl(release_url)

asset = None
for href in re.findall(r'href="([^"]+)"', html_doc):
    href = html.unescape(href)
    if href.startswith("/"):
        full_url = "https://github.com" + href
    else:
        full_url = href
    if f"/{repo}/releases/download/" not in full_url:
        continue
    name = full_url.rsplit("/", 1)[-1]
    if asset_regex.search(name) or asset_regex.search(full_url):
        asset = {"name": name, "url": full_url}
        break

if asset is None:
    raise SystemExit(2)

version = tag[len(tag_strip_prefix):] if tag_strip_prefix and tag.startswith(tag_strip_prefix) else tag
fields = {
    "GITHUB_RELEASE_TAG": tag,
    "GITHUB_RELEASE_VERSION": version,
    "GITHUB_RELEASE_URL": release_url,
    "GITHUB_RELEASE_PUBLISHED_AT": "",
    "GITHUB_ASSET_NAME": asset["name"],
    "GITHUB_ASSET_URL": asset["url"],
    "GITHUB_ASSET_DIGEST": "",
}

for key, value in fields.items():
    print(f"{key}={shlex.quote(value)}")
PY
    )"; then
      warn "Could not parse latest release metadata for ${repo}"
      return 1
    fi
  fi

  while IFS='=' read -r __key __val; do
    [[ -n "$__key" ]] || continue
    # Strip surrounding single quotes produced by shlex.quote()
    __val="${__val#\'}" ; __val="${__val%\'}"
    printf -v "$__key" '%s' "$__val"
  done <<< "$assignments"
}
github_release_append_default_mirrors() {
  if [[ "${GITHUB_RELEASE_NO_DEFAULT_MIRRORS:-0}" == "1" ]]; then
    return
  fi

  if [[ -z "${GITHUB_MIRROR_PREFIXES:-}" && "${#MIRROR_PREFIXES[@]}" -eq 0 ]]; then
    MIRROR_PREFIXES+=(
      "https://gh-proxy.com/"
      "https://gh.dlproxy.workers.dev/"
      "https://ghproxy.vip/"
      "https://gh.llkk.cc/"
    )
  fi
}
github_release_append_env_mirrors() {
  local raw prefix
  raw="${GITHUB_MIRROR_PREFIXES:-}"
  raw="${raw//$'\n'/ }"
  raw="${raw//,/ }"

  for prefix in $raw; do
    MIRROR_PREFIXES+=("$prefix")
  done
}
github_release_normalize_prefix() {
  local prefix
  prefix="$1"

  if [[ -z "$prefix" ]]; then
    printf '\n'
    return
  fi

  if [[ "$prefix" == */ ]]; then
    printf '%s\n' "$prefix"
  else
    printf '%s/\n' "$prefix"
  fi
}
github_release_build_candidate_urls() {
  local asset_url prefix normalized
  asset_url="$1"
  declare -g -a DOWNLOAD_CANDIDATE_URLS=()
  declare -A seen_urls=()

  DOWNLOAD_CANDIDATE_URLS+=("$asset_url")
  seen_urls["$asset_url"]=1

  github_release_append_env_mirrors
  github_release_append_default_mirrors

  for prefix in "${MIRROR_PREFIXES[@]}"; do
    normalized="$(github_release_normalize_prefix "$prefix")"
    [[ -n "$normalized" ]] || continue
    if [[ -z "${seen_urls["${normalized}${asset_url}"]+x}" ]]; then
      DOWNLOAD_CANDIDATE_URLS+=("${normalized}${asset_url}")
      seen_urls["${normalized}${asset_url}"]=1
    fi
  done
}
github_release_verify_sha256() {
  local file_path expected_sha256 actual_sha256
  file_path="$1"
  expected_sha256="$2"

  if [[ -z "$expected_sha256" ]]; then
    return 0
  fi

  ensure_command sha256sum
  actual_sha256="$(sha256sum "$file_path" | awk '{print $1}')"
  [[ "$actual_sha256" == "$expected_sha256" ]]
}
github_release_download_asset() {
  local asset_url expected_sha256 target_path tmp_path candidate_url speed_limit speed_time
  asset_url="$1"
  expected_sha256="$2"
  target_path="$3"

  mkdir -p "$(dirname "$target_path")"

  if [[ -f "$target_path" ]]; then
    if github_release_verify_sha256 "$target_path" "$expected_sha256"; then
      info "Using existing verified file: $target_path"
      return
    fi
    warn "Existing file failed digest verification, re-downloading: $target_path"
    rm -f "$target_path"
  fi

  tmp_path="${target_path}.part"
  github_release_build_candidate_urls "$asset_url"
  speed_limit="${GITHUB_DOWNLOAD_SPEED_LIMIT:-204800}"
  speed_time="${GITHUB_DOWNLOAD_SPEED_TIME:-8}"

  for candidate_url in "${DOWNLOAD_CANDIDATE_URLS[@]}"; do
    rm -f "$tmp_path"
    info "Downloading from: $candidate_url"
    if ! curl \
      -fL \
      --progress-bar \
      --connect-timeout "${GITHUB_DOWNLOAD_CONNECT_TIMEOUT:-5}" \
      --speed-limit "$speed_limit" \
      --speed-time "$speed_time" \
      -o "$tmp_path" \
      "$candidate_url"; then
      warn "Download failed or stayed below ${speed_limit}B/s for ${speed_time}s, trying next candidate"
      rm -f "$tmp_path"
      continue
    fi

    if ! github_release_verify_sha256 "$tmp_path" "$expected_sha256"; then
      warn "Digest mismatch, discarded: $candidate_url"
      rm -f "$tmp_path"
      continue
    fi

    mv "$tmp_path" "$target_path"
    info "Saved to $target_path"
    return
  done

  warn "All download candidates failed for $asset_url"
  return 1
}
