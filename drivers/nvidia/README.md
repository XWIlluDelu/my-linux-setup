# NVIDIA driver and CUDA

Standalone installer for **x86_64 Debian/Ubuntu**. Its package path selects NVIDIA **open kernel modules**, which require Turing or newer GPUs. It does not automate legacy proprietary-only GPUs.

```bash
bash ~/my-linux-setup/manage.sh driver nvidia --check
bash ~/my-linux-setup/manage.sh driver nvidia --apply
```

`--check` fetches NVIDIA's installation guide, release notes, repository package index, and runfile metadata, then inspects local APT/driver state. It does not refresh APT or install packages. Package-managed installation requires open-driver candidates already visible in configured APT sources; if none are listed, follow NVIDIA's distribution-specific [driver installation guide](https://docs.nvidia.com/datacenter/tesla/driver-installation-guide/) first.

## Choose an installation method

| `--method` | Behavior |
|---|---|
| `deb` | Install a selected open-driver branch and, optionally, `cuda-toolkit-X-Y` |
| `run` | Launch NVIDIA's interactive runfile after downloading and checking its published MD5 |
| `manual` | Resolve and print a plan without applying it |
| `skip` | Exit without probing or changing the system |

Modes default to `--check`; `--yes` accepts defaults only when `--apply` is also supplied.

```bash
bash ~/my-linux-setup/manage.sh driver nvidia \
  --apply --method deb --cuda latest --driver-branch latest --install-toolkit
```

### Package-managed path

- `--driver-branch latest` selects the highest compatible branch in the probed candidates. A numeric branch selects that branch.
- `--cuda latest`, `--cuda X.Y`, or `--cuda decide_later` control toolkit selection. When the driver is selected first, the installer resolves compatible toolkit families for it.
- Matching kernel headers are required for DKMS. Secure Boot may require distribution-specific module-signing/MOK enrollment.
- `--lock-driver-branch` uses `apt-mark hold` on matching installed packages. This freezes their **exact versions**, including security updates; it is not a rolling branch pin. A later installer run removes NVIDIA holds before installing its selection.
- The installer configures a supported NVIDIA CUDA repository before installing toolkit packages. Using a different release's repository on an unsupported distro requires explicit consent; the interactive default and `--yes` decline it.

Compatibility selection uses NVIDIA's **corresponding driver version/branch** for each toolkit, shown as `min_driver` in the probe output. It does not use the lower CUDA minor-version compatibility floor, whose feature and PTX limitations may matter for newly built applications. See the [release notes](https://docs.nvidia.com/cuda/cuda-toolkit-release-notes/index.html).

### Runfile path

Runfiles differ by toolkit version:

- **Before CUDA 13.4:** the Linux installer bundles a driver. Start from a text TTY with Secure Boot disabled. The script can purge APT-managed NVIDIA/CUDA packages and stop the display manager after interactive confirmation; `--yes` refuses these destructive preparations. A later installation failure can leave the driver removed or display manager stopped, so keep a recovery console available.
- **CUDA 13.4 and later:** Linux runfiles are toolkit-only. The script keeps the existing driver and display manager. Install a compatible driver separately; an existing APT-managed CUDA toolkit must be removed before mixing installation methods.

The installer is downloaded and its upstream MD5 checked **before** any purge or display-manager stop. MD5 detects transfer corruption; HTTPS to NVIDIA provides the download's source trust. `run` requires an interactive terminal.

## Verify after installation

If the driver changed, reboot before checking:

```bash
nvidia-smi
nvcc --version  # when the toolkit is installed and its bin directory is on PATH
modinfo nvidia | head
```

Machine-specific CUDA PATH entries belong in local shell configuration, not `assets/`.

## Implementation

- `install-nvidia-cuda.sh`: selection, preflight, and execution
- `probe_nvidia_metadata.py`: live metadata and local candidate discovery

Old installer commands remain in Git history. The current installer downloads the keyring for the selected repository rather than using a bundled binary copy.
