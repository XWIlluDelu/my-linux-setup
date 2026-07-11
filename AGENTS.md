# my-linux-setup Agent Notes

## Scope

This repository automates one local Linux setup. Prefer small, auditable shell changes over broad abstractions.

## Hard rules

- Preserve dry-run safety: commands default to `--check`; mutation must require `--apply` or a documented execution flag that explicitly implies apply mode.
- Do not chain `setup stage1` and `setup stage2`. Stage 1 rewrites the Btrfs layout; verify it and reboot before Stage 2.
- Keep machine-specific shell paths, proxy variables, SDK paths, and manual tool hooks out of `assets/`.
- Do not commit credentials, API keys, host secrets, subscription URLs, or generated runtime logs.
- Do not silently broaden full-flow distro support. `setup stage2` is Debian/Ubuntu + Btrfs-root oriented even though several reusable tasks support more package managers.

## Structure

| Path | Role |
|---|---|
| `manage.sh` | Stable public CLI dispatcher; contains no setup implementation |
| `commands/` | Public command handlers matching the CLI groups; `menu.sh` is optional UI |
| `tasks/` | Focused operations used by commands; `tasks/apps/external/` owns app-specific adapters |
| `lib/` | Domain helpers split by runtime, packages, preflight, downloads, state, Btrfs, boot, and results |
| `drivers/nvidia/` | NVIDIA/CUDA independent module |
| `assets/` | Repo-managed config payloads only |
| `extras/` | Standalone tools and local fix notes; not part of `manage.sh` |

## Verification

Before finishing shell changes:

```bash
bash tests/run.sh
python3 -m py_compile drivers/nvidia/probe_nvidia_metadata.py extras/my-ai-tools/claude-session-manager/session_manager_server.py
bash manage.sh check
```

`manage.sh check` may perform network metadata probes through child scripts; use targeted `--check` commands if a no-network smoke test is needed.
