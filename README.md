# my-linux-setup

Personal Linux workstation setup and maintenance scripts. The main setup is a two-stage Debian/Ubuntu + Btrfs workflow; individual app tasks and optional tools can also be used separately. Examples assume a checkout at `~/my-linux-setup`.

## Safety model

- Dry-run by default: commands default to `--check`. Mutation requires `--apply`, setup/update `--yes`, or mirror `--auto`/`--reset`; those latter flags explicitly enter apply mode.
- `setup stage1` rewrites the Btrfs subvolume layout. Verify its reported layout, reboot manually, then run `stage2`.
- `setup stage2` targets Debian/Ubuntu + Btrfs root; some low-level tasks support apt/dnf/zypper/pacman, but the full setup flow is not cross-distro.
- `extras/` holds standalone tools and issue notes and is not part of the `manage.sh` main flow.

## Main entry

```bash
bash ~/my-linux-setup/manage.sh --help
bash ~/my-linux-setup/manage.sh check
```

Running `manage.sh` with no arguments opens an interactive menu; with arguments it dispatches by subcommand. `check` previews the flows and fetches live NVIDIA metadata. For offline verification, run `bash tests/run.sh`.

| Command | Action |
|---|---|
| `setup stage1` | Convert Btrfs root to `@rootfs` + `@home`, create a safety copy/snapshot, then stop for verification |
| `setup stage2` | After reboot, initialize snapper, remove snap, upgrade the system, install selected components, cleanup |
| `update` / `update all` | Update system packages, refresh detected managed apps and shell components, cleanup |
| `update packages` | Run only the system package upgrade |
| `update apps` | Refresh detected or interactively selected managed apps and shell components |
| `maintain repair` | Repair Debian/Ubuntu package state and rebuild related kernel artifacts |
| `maintain mirror` | Probe, switch, or restore the APT mirror |
| `snapshot create` | Create a read-only snapper snapshot |
| `snapshot rollback` | Create a boot-level rollback target with snapper |
| `shell sync` | Rewrite managed shell configuration and state; remove only the marked legacy tmux file |
| `driver nvidia` | Standalone NVIDIA driver + CUDA installer |

## Repository map

| Path | Authority |
|---|---|
| `manage.sh` | Stable public command names and dispatch only |
| `commands/` | One handler for each public command group, plus the optional menu |
| `tasks/` | Focused installation and system operations composed by commands |
| `lib/` | Shared helpers, one domain per file; `common.sh` is the compatibility import |
| `assets/` | Configuration files deployed by setup |
| `drivers/` | Independent hardware installers and their documentation |
| `extras/` | Post-install configuration records, fixes, and optional tools; never run automatically |
| `tests/` | Non-mutating command, failure-path, and helper contracts |

## Setup flow

Stage 1 supports a top-level Btrfs root or an existing `@rootfs`, with `/home` still inside root and `/boot` not separately mounted. Other layouts, including an existing `@` root, need manual preparation. Use a fresh, idle installation and keep an external backup: the safety copy/snapshot is on the same filesystem, not a disk-failure backup.

```bash
bash ~/my-linux-setup/manage.sh setup stage1 --apply
```

Stage 1 checks capacity before copying data and stops before rebooting. Verify the generated `/etc/fstab`, Btrfs default subvolume, and boot files, then reboot manually. Confirm `/` is `@rootfs` and `/home` is `@home` with `findmnt /` and `findmnt /home` before choosing **one** Stage 2 profile:

```bash
bash ~/my-linux-setup/manage.sh setup stage2 --apply --profile desktop
bash ~/my-linux-setup/manage.sh setup stage2 --apply --profile server
```

Profile defaults:

| Item | `desktop` | `server` |
|---|---:|---:|
| shell environment | yes | yes |
| desktop base packages | yes | no |
| Chinese input / font support | yes | no |
| VS Code | yes | no |
| Microsoft Edge | yes | no |
| NVIDIA installer | yes | yes |
| Flatpak / WeChat / Clash Verge Rev / Zotero / Obsidian / Ghostty / Maple Font / Miniforge | no | no |

Without `--yes`, `stage2 --apply` asks the user to confirm the profile and install items.

## Update and maintenance

Full routine update:

```bash
bash ~/my-linux-setup/manage.sh update --apply
```

System packages only:

```bash
bash ~/my-linux-setup/manage.sh update packages --apply
```

Refresh managed apps and shell components:

```bash
bash ~/my-linux-setup/manage.sh update apps --apply
```

`update apps` selects components it detects as installed or managed: desktop essentials, Edge, VS Code, Flatpak, WeChat, Clash Verge Rev, Zotero, Obsidian, Ghostty, Maple Font, Miniforge, and the shell environment. With a TTY present you can add or remove items interactively. `--yes` applies the detection result without prompting.

Ghostty installs the bundled config only when `~/.config/ghostty/config` is absent; updates keep existing configuration.

Repair package state:

```bash
bash ~/my-linux-setup/manage.sh maintain repair --apply
```

APT mirror:

```bash
bash ~/my-linux-setup/manage.sh maintain mirror --list
bash ~/my-linux-setup/manage.sh maintain mirror --auto
bash ~/my-linux-setup/manage.sh maintain mirror --reset
```

Mirror changes cover `/etc/apt/sources.list` and the distro's `debian.sources` or `ubuntu.sources`. Security repositories and unrelated sources stay unchanged. The command backs up changed sources, rejects partial APT refresh failures, and restores the original sources on failure; it also attempts to refresh metadata from the restored sources.

## Shell config boundaries

Managed configuration and state:

- `~/.profile`
- `~/.bashrc`
- `~/.zshrc`
- `~/.config/shell/env.sh`
- `~/.config/shell/aliases.sh`
- `~/.config/starship.toml`
- `~/.local/state/linux-setup/shell-env-profile`
- `~/.local/state/linux-setup/shell-env.env`

Fresh shell setup and `shell sync` back up existing shell configuration under `~/.local/state/linux-setup/backups/shell-<timestamp>-<pid>/` before overwriting it. Fresh setup also replaces the managed Zinit checkout and Starship binary; normal shell updates preserve configuration. A sync removes `~/.tmux.conf` only when its first line is the legacy marker `# Linux Setup tmux config`; unrelated tmux files are untouched.

Rewrite the managed shell files and state:

```bash
bash ~/my-linux-setup/manage.sh shell sync --apply --profile desktop
bash ~/my-linux-setup/manage.sh shell sync --apply --profile server
```

`shell sync` requires that the target user already has linux-setup-managed shell state. Machine-specific paths, manually installed Node.js, temporary proxies, SDK paths, Miniforge shell hooks, etc. are not written into `assets/`; the local recovery strategy is in [`LOCAL_ENV_AGENT_NOTES.md`](LOCAL_ENV_AGENT_NOTES.md).

## Snapshots

```bash
bash ~/my-linux-setup/manage.sh snapshot create --apply
bash ~/my-linux-setup/manage.sh snapshot rollback --apply --snapshot <N>
```

`rollback` requires a root snapper configuration, a positive snapshot number, GRUB, and a kernel/initramfs inside the snapshot. A separate `/boot` is not supported. `/home` remains unchanged when mounted from `@home`. The command preserves unrelated entries in `grub/custom.cfg` and reboots by default; pass `--no-reboot` to inspect the prepared target first.

## NVIDIA

```bash
bash ~/my-linux-setup/manage.sh driver nvidia --check
bash ~/my-linux-setup/manage.sh driver nvidia --apply
```

Module notes in [`drivers/nvidia/README.md`](drivers/nvidia/README.md).

## Downloads and verification

GitHub release downloads use upstream SHA-256 metadata when present. Only digest-verified assets can use mirror fallbacks or a cached file. Assets without a digest are fetched directly from the origin each time. Ghostty's Debian/Ubuntu packages and Zotero's APT repository are community-maintained, not vendor-built packages.

```bash
bash tests/run.sh
python3 -m py_compile drivers/nvidia/probe_nvidia_metadata.py extras/my-ai-tools/claude-session-manager/session_manager_server.py
bash manage.sh check
```

The tests exercise fake commands and temporary data, including failed mounts, failed downloads, interrupted deletion, and hostile session text. They do not validate an actual boot migration, driver installation, or live GNOME session; those need a disposable VM or suitable test machine. Upstream interface evidence is collected in [maintenance notes](MAINTENANCE.md).

## Extras

These include both runnable tools and historical workstation records. Version numbers in incident/setup notes describe the recorded environment, not a requirement to downgrade a new installation.

| Directory | Contents |
|---|---|
| `extras/app-grid/` | GNOME app grid analysis and folder organization |
| `extras/edge-sync-fix/` | Edge on Linux sync failure investigation and fix |
| `extras/fcitx5-vinput/` | vinput 2.4 Bailian / Gemini gateway configuration and paired profile switching |
| `extras/ghostty-default-terminal/` | GNOME `xdg-terminal-exec` default terminal setup |
| `extras/pinky/` | Pinky GNOME Shell extension: pin window geometry or toggle always-on-top |
| `extras/nautilus-enhancements/` | Nautilus `Open in Terminal` and `Copy Path` enhancements |
| `extras/psychtoolbox/` | Psychtoolbox 3 local install notes |
| `extras/wemeet-screen-share-fix/` | Wemeet screen-share black-screen fix |
| `extras/zeabur/` | Zeabur server VPSization notes |
| `extras/my-ai-tools/` | [Local session browser](extras/my-ai-tools/claude-session-manager/README.md); [CLIProxyAPIPlus and Mihomo VPS notes](extras/my-ai-tools/cpa-deploy/README.md) |
