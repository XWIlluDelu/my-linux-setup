#!/usr/bin/env bash

# systemd, initramfs, and GRUB integration.

systemd_unit_exists() {
  local unit
  unit="$1"

  if ! command -v systemctl >/dev/null 2>&1; then
    return 1
  fi

  systemctl list-unit-files "$unit" --no-legend 2>/dev/null | grep -q "^$unit"
}
enable_unit_if_exists() {
  local unit
  unit="$1"

  if systemd_unit_exists "$unit"; then
    run_as_root systemctl enable --now "$unit"
  else
    warn "systemd unit not found, skipped: $unit"
  fi
}
rebuild_initramfs_if_possible() {
  if command -v update-initramfs >/dev/null 2>&1; then
    run_as_root update-initramfs -u -k all
    return 0
  fi

  if command -v dracut >/dev/null 2>&1; then
    run_as_root dracut -f
    return 0
  fi

  if command -v mkinitcpio >/dev/null 2>&1; then
    run_as_root mkinitcpio -P
    return 0
  fi

  warn "No supported initramfs rebuild command found."
}
disable_grub_btrfs_rootflags_if_possible() {
  local file stamp changed_any=0 backup_dir backup_file

  if ! command_exists python3; then
    warn "python3 is unavailable, so GRUB btrfs rootflags injection could not be disabled."
    return 1
  fi

  for file in /etc/grub.d/10_linux /etc/grub.d/20_linux_xen; do
    [[ -f "$file" ]] || continue

    if ! grep -Fq 'rootflags=subvol=${rootsubvol}' "$file"; then
      continue
    fi

    stamp="$(date +%Y%m%d-%H%M%S)"
    backup_dir="/var/backups/linux-setup-grub"
    backup_file="${backup_dir}/$(basename "$file").linux-setup.bak.${stamp}"
    run_as_root mkdir -p "$backup_dir"
    run_as_root cp -a "$file" "$backup_file"
    run_as_root chmod 0644 "$backup_file"
    run_as_root python3 - "$file" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()
lines = text.splitlines(keepends=True)
out = []
changed = False

for line in lines:
    if 'rootflags=subvol=${rootsubvol}' in line and 'GRUB_CMDLINE_LINUX=' in line and not line.lstrip().startswith('#'):
        indent = line[: len(line) - len(line.lstrip())]
        out.append(
            f"{indent}: # linux-setup: keep btrfs root selection driven by the default subvolume for snapper rollback.\n"
        )
        changed = True
        continue
    out.append(line)

if changed:
    path.write_text(''.join(out))
PY
    changed_any=1
  done

  if [[ "$changed_any" -eq 1 ]]; then
    info "Disabled GRUB btrfs rootflags injection so the default subvolume can drive snapper rollback boots."
  else
    info "No GRUB btrfs rootflags injection was detected."
  fi
}
ensure_grub_saved_default_if_possible() {
  local grub_defaults backup stamp
  grub_defaults="/etc/default/grub"

  [[ -f "$grub_defaults" ]] || return 0

  if grep -Eq '^GRUB_DEFAULT=saved$' "$grub_defaults"; then
    info "GRUB_DEFAULT is already set to 'saved'."
    return 0
  fi

  stamp="$(date +%Y%m%d-%H%M%S)"
  backup="/var/backups/linux-setup-grub/default-grub.bak.${stamp}"
  run_as_root mkdir -p /var/backups/linux-setup-grub
  run_as_root cp -a "$grub_defaults" "$backup"
  run_as_root python3 - "$grub_defaults" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()

if re.search(r'^GRUB_DEFAULT=', text, flags=re.M):
    text = re.sub(r'^GRUB_DEFAULT=.*$', 'GRUB_DEFAULT=saved', text, flags=re.M)
else:
    if not text.endswith('\n'):
        text += '\n'
    text += 'GRUB_DEFAULT=saved\n'

path.write_text(text)
PY
  info "Configured GRUB_DEFAULT=saved so rollback can retarget the boot entry."
}
rebuild_grub_if_possible() {
  if command -v update-grub >/dev/null 2>&1; then
    run_as_root update-grub
    return 0
  fi

  if command -v grub-mkconfig >/dev/null 2>&1; then
    if [[ -d /boot/grub ]]; then
      run_as_root grub-mkconfig -o /boot/grub/grub.cfg
      return 0
    fi

    if [[ -d /boot/grub2 ]]; then
      run_as_root grub-mkconfig -o /boot/grub2/grub.cfg
      return 0
    fi

    warn "grub-mkconfig exists, but no grub.cfg path was detected."
    return 0
  fi

  warn "No supported grub rebuild command found."
}
