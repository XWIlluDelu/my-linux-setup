# NVIDIA

现在这一目录已经从“原始命令备份”升级为可交互的 NVIDIA 驱动 + CUDA 安装入口。

## 推荐入口

```bash
bash ~/my-linux-setup/setup.sh nvidia --check
bash ~/my-linux-setup/setup.sh nvidia --apply
```

也可以直接运行：

```bash
bash ~/my-linux-setup/nvidia/install-nvidia-cuda.sh --check
bash ~/my-linux-setup/nvidia/install-nvidia-cuda.sh --apply
```

## 当前策略

- package-managed 路径负责安装指定 `open` 驱动分支，并可选安装 `cuda-toolkit-X-Y`。
- package-managed 路径支持两类分支选择：明确分支可选是否锁定；`latest` 会安装当前最高兼容分支且不锁定。
- `.run` 模式会直接启动 NVIDIA 官方 runfile 安装器，按它自己的默认交互流程安装，通常会进入闭源驱动 + CUDA 的官方路径。
- `.run` 模式会先让你选 CUDA 版本，再做谨慎预检：图形会话里直接拒绝、Secure Boot 默认拒绝、发现 APT 管理的 NVIDIA/CUDA 包时只在明确确认后才会清理。
- `preview only` 路径会先解析 open 驱动分支与 CUDA 版本，再打印 deb/open-driver 包名、可选锁定策略和 runfile 链接，不改系统。
- CUDA 版本选择支持 `latest`、明确版本和 `decide later`；其中 `decide later` 只用于 `.deb` / `manual` 路径。
- 当先选定驱动分支时，脚本会反向探测该分支当前最合适的 CUDA 版本。
- `--yes` 走保守默认值：不会自动锁定驱动分支，也不会在不受支持的发行版上自动启用 CUDA repo override。

## 文件

- [install-nvidia-cuda.sh](install-nvidia-cuda.sh)
- [probe_nvidia_metadata.py](probe_nvidia_metadata.py)
- [10-nvidia-driver-cuda.original.sh](10-nvidia-driver-cuda.original.sh)
- [cuda-keyring_1.1-1_all.deb](cuda-keyring_1.1-1_all.deb)

## 说明

- 原始脚本仍保留，作为你当时真实跑过的一组命令参考。
- 新脚本会优先探测 NVIDIA 官方元数据，再决定 `.deb` repo、runfile 和兼容驱动范围。
- 对于像 Ubuntu 25.10 这种当前没有官方 CUDA `.deb` 仓库的系统，脚本会显式提示并在需要时询问是否允许使用较新的受支持 Ubuntu repo 作为 override。
