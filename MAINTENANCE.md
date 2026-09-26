# Maintenance contracts and upstream interfaces

## Safety contracts

- Commands default to inspection. Repository tasks require `--apply`; the setup/update `--yes`, mirror `--auto`/`--reset`, and session server `--serve` flags are documented execution modes. An inherited `APPLY=1` must not enable writes.
- Stage 1 and Stage 2 are separate invocations with a verification and reboot between them. Snapshot boot switching requires `/boot` inside the root subvolume; a separate EFI system partition is allowed.
- Unmount failure must preserve a temporary mount and its contents. Cleanup uses `rmdir` only after a successful unmount, never recursive deletion of a mount tree.
- Optional app failures must reach the per-component result log and the command's exit status. An error in one app must not run its remaining installation commands or suppress unrelated selected apps.
- A mirror is a transport fallback, not a trust source. Use it only when the origin supplied a supported digest; unverified assets are downloaded directly and not reused from cache.
- Session text, IDs, paths, and HTTP origins are untrusted input even in a loopback-only UI. Deletion must not follow symlinks or report success before the server confirms it.

## Upstream checks

Reviewed on **2026-09-26**. These are interface observations, not pinned application versions; package availability still depends on distribution, architecture, and configured repositories.

| Interface | Finding and implementation |
|---|---|
| [CUDA release notes](https://docs.nvidia.com/cuda/cuda-toolkit-release-notes/index.html) | The corresponding-driver table now uses **Toolkit Version / Driver Version**. The parser also accepts the older Linux-column layout and keeps branch selection separate from the minor-version compatibility floor. |
| [CUDA Linux installation guide](https://docs.nvidia.com/cuda/cuda-installation-guide-linux/index.html) | CUDA 13.4+ Linux runfiles omit the driver. Metadata carries whether a runfile bundles a driver so toolkit-only installation cannot trigger driver purge. Runfiles use NVIDIA's published MD5 plus HTTPS. |
| [GitHub release asset API](https://docs.github.com/en/rest/releases/assets) | `digest` may be null. Only a valid `sha256:` value enables digest verification, cache reuse, and mirror fallback. Release metadata is assigned literally, without `eval`. |
| [Ghostty Linux packages](https://ghostty.org/docs/install/binary#linux) · [Debian community releases](https://github.com/dariogriffo/ghostty-debian/releases) · [Ubuntu community releases](https://github.com/mkasberg/ghostty-ubuntu/releases) | Debian assets now use a dot before the distro codename; the matcher accepts both `.<codename>_<arch>.deb` and the earlier `+<codename>_<arch>.deb`. Ubuntu keeps its separate `<arch>_<release>.deb` format. Unsupported distro/architecture combinations are not cross-installed. |
| [Zotero Linux installation](https://www.zotero.org/support/installation#linux) · [zotero-deb](https://github.com/retorquere/zotero-deb) | The Debian repository is community-maintained. The adapter writes its documented signed APT repository and keyring directly, without executing a downloaded setup script as root. |
| [Obsidian](https://obsidian.md/download), [Clash Verge Rev](https://github.com/clash-verge-rev/clash-verge-rev/releases), [Maple Font](https://github.com/subframe7536/maple-font/releases), [Miniforge](https://github.com/conda-forge/miniforge/releases) | Existing project sources and installation choices remain in use. No fixed-version bump is needed for adapters that already discover releases. |
| [Mihomo TUN](https://wiki.metacubex.one/en/config/inbound/tun/) · [CLIProxyAPIPlus config](https://github.com/router-for-me/CLIProxyAPIPlus/blob/main/config.example.yaml) | Use `tun: {enable: false}` for the explicit-proxy VPS setup and SSH tunnels for private management. Public `Empty reply` alone does not identify a cloud-provider fault. |
| [Psychtoolbox versions](https://psychtoolbox.org/versions.html) | The macOS/Windows licensing change does not justify pinning Linux to 3.0.19.16. The pinned workstation record remains historical; the timing-bypass smoke test is not experiment validation. |

## Verification boundaries

`bash tests/run.sh` checks shell syntax, CLI/doc contracts, and offline regressions with temporary files and command substitutes. Python compilation checks both first-party Python entry points. With Node.js installed, the suite also checks UI escaping, deletion failure handling, and storage accounting.

`bash manage.sh check` adds a live NVIDIA metadata probe. It is useful for detecting upstream HTML/package changes, but does not validate a real package transaction, Btrfs migration, GRUB boot, or GPU installation. Test those in a disposable VM or on appropriate hardware before applying to important data. GNOME extensions and the historical desktop workarounds require their stated desktop/runtime environment.
