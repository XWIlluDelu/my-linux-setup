#!/usr/bin/env bash

# Btrfs layout discovery and capacity calculations.

btrfs_layout_required_kib() {
  local mode copied_kib
  mode="$1"
  copied_kib="$2"
  [[ "$copied_kib" =~ ^[0-9]+$ ]] || return 1

  case "$mode" in
    flat-root-to-rootfs-home)
      printf '%s\n' "$((copied_kib * 2))"
      ;;
    split-home-from-existing-rootfs)
      printf '%s\n' "$copied_kib"
      ;;
    *)
      return 1
      ;;
  esac
}

btrfs_layout_has_capacity() {
  local available_kib required_kib
  available_kib="$1"
  required_kib="$2"
  [[ "$available_kib" =~ ^[0-9]+$ && "$required_kib" =~ ^[0-9]+$ ]] || return 1
  (( available_kib >= required_kib ))
}

require_btrfs_root() {
  local fstype
  fstype="$(findmnt -nro FSTYPE / 2>/dev/null || true)"
  [[ "$fstype" == "btrfs" ]] || die "Root filesystem is '$fstype', not btrfs."
}
current_root_source() {
  findmnt -nro SOURCE /
}
current_root_subvol_path() {
  local root_src root_opts subvol
  root_src="$(current_root_source)"

  if [[ "$root_src" == *'['*']'* ]]; then
    subvol="${root_src#*[}"
    subvol="${subvol%]}"
    subvol="${subvol#/}"
    if [[ "$subvol" == "/" ]]; then
      printf '\n'
    else
      printf '%s\n' "$subvol"
    fi
    return 0
  fi

  root_opts="$(findmnt -nro OPTIONS / 2>/dev/null || true)"
  subvol="$(
    printf '%s\n' "$root_opts" \
      | tr ',' '\n' \
      | awk -F= '$1=="subvol" {print $2; exit}'
  )"
  subvol="${subvol#/}"
  if [[ "$subvol" == "/" ]]; then
    printf '\n'
  else
    printf '%s\n' "$subvol"
  fi
}
stable_root_subvol_path() {
  local root_subvol
  root_subvol="$(current_root_subvol_path)"

  if [[ "$root_subvol" == *"/.snapshots/"* ]]; then
    printf '%s\n' "${root_subvol%%/.snapshots/*}"
    return 0
  fi

  printf '%s\n' "$root_subvol"
}
stable_snapshots_subvol_path() {
  local stable_root_subvol
  stable_root_subvol="$(stable_root_subvol_path)"

  if [[ -n "$stable_root_subvol" ]]; then
    printf '%s/.snapshots\n' "$stable_root_subvol"
  else
    printf '.snapshots\n'
  fi
}
current_root_device() {
  local root_src root_dev
  root_src="$(current_root_source)"
  root_dev="${root_src%%[*}"
  if [[ -b "$root_dev" ]]; then
    readlink -f "$root_dev"
    return 0
  fi

  printf '%s\n' "$root_dev"
}
current_root_uuid() {
  local uuid root_dev link
  uuid="$(findmnt -nro UUID / 2>/dev/null || true)"
  if [[ -n "$uuid" ]]; then
    printf '%s\n' "$uuid"
    return 0
  fi

  root_dev="$(current_root_device)"

  if command_exists lsblk; then
    uuid="$(lsblk -ndo UUID "$root_dev" 2>/dev/null | awk 'NF {print; exit}' || true)"
    if [[ -n "$uuid" ]]; then
      printf '%s\n' "$uuid"
      return 0
    fi
  fi

  if [[ -d /dev/disk/by-uuid ]]; then
    for link in /dev/disk/by-uuid/*; do
      [[ -L "$link" ]] || continue
      if [[ "$(readlink -f "$link")" == "$root_dev" ]]; then
        basename "$link"
        return 0
      fi
    done
  fi

  uuid="$(blkid -s UUID -o value "$root_dev" 2>/dev/null || true)"
  printf '%s\n' "$uuid"
}
normalized_btrfs_opts() {
  local target raw normalized
  target="${1:-/}"
  raw="$(findmnt -nro OPTIONS "$target" 2>/dev/null || true)"
  normalized="$(
    printf '%s\n' "$raw" \
      | tr ',' '\n' \
      | grep -vE '^(subvol=|subvolid=|fsroot=)' \
      | paste -sd, -
  )"

  if [[ -n "$normalized" ]]; then
    printf '%s\n' "$normalized"
  else
    printf 'defaults\n'
  fi
}
with_subvol_opt() {
  local base_opts subvol
  base_opts="$1"
  subvol="$2"

  if [[ -n "$base_opts" ]]; then
    printf '%s,subvol=%s\n' "$base_opts" "$subvol"
  else
    printf 'subvol=%s\n' "$subvol"
  fi
}
