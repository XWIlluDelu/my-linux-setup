# my-linux-setup Agent Notes

## Scope

This repository automates one local Linux setup. Prefer small, auditable shell changes over broad abstractions.

## Hard rules

- Preserve dry-run safety: scripts default to `--check`; destructive or system-mutating behavior must require `--apply`.
- Do not chain `setup stage1` and `setup stage2`. Stage 1 rewrites Btrfs layout and reboots.
- Keep machine-specific shell paths, proxy variables, SDK paths, and manual tool hooks out of `assets/`.
- Do not commit credentials, API keys, host secrets, subscription URLs, or generated runtime logs.
- Do not silently broaden full-flow distro support. `setup stage2` is Debian/Ubuntu + Btrfs-root oriented even though several reusable tasks support more package managers.

## Structure

| Path | Role |
|---|---|
| `manage.sh` | Public dispatcher and interactive menu |
| `lib/common.sh` | Shared safety, package-manager, preflight, download, and result helpers |
| `flows/` | User-facing multi-step workflows |
| `tasks/` | Reusable focused operations |
| `commands/` | Public maintenance/update/snapshot/shell subcommands |
| `drivers/nvidia/` | NVIDIA/CUDA independent module |
| `assets/` | Repo-managed config payloads only |
| `extras/` | Standalone tools and local fix notes; not part of `manage.sh` |

## Verification

Before finishing shell changes:

```bash
for f in $(find . -name '*.sh' -not -path './.git/*' | sort); do bash -n "$f" || exit 1; done
python3 -m py_compile drivers/nvidia/probe_nvidia_metadata.py extras/my-ai-tools/claude-session-manager/session_manager_server.py
bash manage.sh --help
bash manage.sh check
```

`manage.sh check` may perform network metadata probes through child scripts; use targeted `--check` commands if a no-network smoke test is needed.
