# my-linux-setup

A collection of Linux setup, update, and maintenance scripts. Default repo path: `~/my-linux-setup`.

## Safety model

- Dry-run by default: scripts default to `--check`; only an explicit `--apply` mutates the system.
- `setup stage1` rewrites the Btrfs subvolume layout and reboots; do not run it back-to-back with `stage2`.
- `setup stage2` targets Debian/Ubuntu + Btrfs root; some low-level tasks support apt/dnf/zypper/pacman, but the full setup flow is not cross-distro.
- `extras/` holds standalone tools and issue notes and is not part of the `manage.sh` main flow.

## Main entry

```bash
bash ~/my-linux-setup/manage.sh --help
bash ~/my-linux-setup/manage.sh check
```

Running `manage.sh` with no arguments opens an interactive menu; with arguments it dispatches by subcommand.

| Command | Action |
|---|---|
| `setup stage1` | Convert Btrfs root to `@rootfs` + `@home`, create a safety snapshot, reboot |
| `setup stage2` | After reboot, initialize snapper, remove snap, upgrade the system, install selected components, cleanup |
| `update` / `update all` | Update system packages, refresh detected managed apps and shell components, cleanup |
| `update packages` | Run only the system package upgrade |
| `update apps` | Refresh detected or interactively selected managed apps and shell components |
| `maintain repair` | Repair Debian/Ubuntu package state and rebuild related kernel artifacts |
| `maintain mirror` | Probe, switch, or restore the APT mirror |
| `snapshot create` | Create a read-only snapper snapshot |
| `snapshot rollback` | Create a boot-level rollback target with snapper |
| `shell sync` | Rewrite only the managed shell config files |
| `driver nvidia` | Standalone NVIDIA driver + CUDA installer |

## Setup flow

Stage 1: run only on a fresh install, after confirming root is Btrfs and `/home` is not a separate mount.

```bash
bash ~/my-linux-setup/manage.sh setup stage1 --apply
```

After the reboot, run Stage 2:

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

`update apps` first detects the current managed state: installed/managed Edge, VS Code, Flatpak, WeChat, Clash Verge Rev, Zotero, Obsidian, Ghostty, Maple Font, Miniforge, and the shell environment are selected by default; with a TTY present you can add or remove items interactively, and `--yes` uses the detection result.

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

## Shell config boundaries

Managed files:

- `~/.profile`
- `~/.bashrc`
- `~/.zshrc`
- `~/.config/shell/env.sh`
- `~/.config/shell/aliases.sh`
- `~/.config/starship.toml`

Rewrite only these files:

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

`rollback` reboots by default; to only create the rollback target without rebooting, pass `--no-reboot`.

## NVIDIA

```bash
bash ~/my-linux-setup/manage.sh driver nvidia --check
bash ~/my-linux-setup/manage.sh driver nvidia --apply
```

Module notes in [`drivers/nvidia/README.md`](drivers/nvidia/README.md).

## Extras

| Directory | Contents |
|---|---|
| `extras/app-grid/` | GNOME app grid analysis and folder organization |
| `extras/edge-sync-fix/` | Edge on Linux sync failure investigation and fix |
| `extras/fcitx5-vinput/` | Local `fcitx5-vinput` setup notes |
| `extras/ghostty-default-terminal/` | GNOME `xdg-terminal-exec` default terminal setup |
| `extras/pinky/` | Pinky GNOME Shell extension: shortcut to pin window position and size |
| `extras/nautilus-enhancements/` | Nautilus `Open in Terminal` and `Copy Path` enhancements |
| `extras/psychtoolbox/` | Psychtoolbox 3 local install notes |
| `extras/wemeet-screen-share-fix/` | Wemeet screen-share black-screen fix |
| `extras/zeabur/` | Zeabur server VPSization notes |
| `extras/my-ai-tools/` | Standalone local/remote helper tool notes |
