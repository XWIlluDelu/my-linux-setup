# NVIDIA driver and CUDA

This directory is the standalone NVIDIA installation module; the main entry point is still the repo-root `manage.sh`.

```bash
bash ~/my-linux-setup/manage.sh driver nvidia --check
bash ~/my-linux-setup/manage.sh driver nvidia --apply
```

Or run directly:

```bash
bash ~/my-linux-setup/drivers/nvidia/install-nvidia-cuda.sh --check
bash ~/my-linux-setup/drivers/nvidia/install-nvidia-cuda.sh --apply
```

## Modes

| Mode | Behavior |
|---|---|
| `--check` | Probes NVIDIA's official metadata, resolves optional driver branches, CUDA versions, repo/runfile links; does not change the system |
| `.deb` package-managed | Installs the specified `open` driver branch; optionally pins the branch; optionally installs `cuda-toolkit-X-Y` |
| `.run` | Downloads the CUDA runfile and hands off to NVIDIA's official installer; follows the official interactive path and may replace the existing driver |
| `manual` / `skip` | Prints the manual path or skips changes |

## Key strategy

- The driver branch may be a specific branch or `latest`; `latest` uses the highest compatible open branch and does not pin.
- CUDA may be `latest`, a specific version, or `decide later`; `decide later` is only valid for the `.deb` / `manual` paths.
- When a driver branch is chosen first, the script reverse-resolves the CUDA versions compatible with that branch.
- The `.run` path refuses to run inside a graphical session, refuses when Secure Boot is enabled, and requires explicit confirmation to clean up when APT-managed NVIDIA/CUDA packages are detected.
- `--yes` uses conservative defaults: it does not auto-pin the driver branch and does not auto-enable the CUDA repo override on unsupported distros.
- `stage2` no longer hardcodes distro special cases; NVIDIA details are left to this installer's probing and interactive/script arguments.

## Scripted example

```bash
bash ~/my-linux-setup/drivers/nvidia/install-nvidia-cuda.sh \
  --apply \
  --method deb \
  --cuda latest \
  --driver-branch latest \
  --install-toolkit
```

## Files

- `install-nvidia-cuda.sh` — main installer
- `probe_nvidia_metadata.py` — official metadata parser
- `10-nvidia-driver-cuda.original.sh` — original command reference
- `cuda-keyring_1.1-1_all.deb` — local keyring package copy
