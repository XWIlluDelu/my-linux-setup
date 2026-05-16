# NVIDIA 驱动与 CUDA

本目录是独立的 NVIDIA 安装模块，主入口仍通过仓库根 `manage.sh` 调用。

```bash
bash ~/my-linux-setup/manage.sh driver nvidia --check
bash ~/my-linux-setup/manage.sh driver nvidia --apply
```

也可直接运行：

```bash
bash ~/my-linux-setup/drivers/nvidia/install-nvidia-cuda.sh --check
bash ~/my-linux-setup/drivers/nvidia/install-nvidia-cuda.sh --apply
```

## 模式

| 模式 | 行为 |
|---|---|
| `--check` | 探测 NVIDIA 官方元数据，解析可选驱动分支、CUDA 版本、repo/runfile 链接，不改系统 |
| `.deb` package-managed | 安装指定 `open` 驱动分支；可选择锁定分支；可选安装 `cuda-toolkit-X-Y` |
| `.run` | 下载 CUDA runfile 并交给 NVIDIA 官方安装器；会走官方交互路径，可能替换现有驱动 |
| `manual` / `skip` | 打印人工路径或跳过修改 |

## 关键策略

- 驱动分支可选明确分支或 `latest`；`latest` 使用当前最高兼容 open 分支且不锁定。
- CUDA 可选 `latest`、明确版本、`decide later`；`decide later` 只用于 `.deb` / `manual` 路径。
- 先选驱动分支时，脚本会反向解析该分支兼容的 CUDA 版本。
- `.run` 路径会在图形会话中拒绝执行；Secure Boot 启用时拒绝执行；发现 APT 管理的 NVIDIA/CUDA 包时需要明确确认清理。
- `--yes` 使用保守默认：不自动锁定驱动分支，不在不受支持的发行版上自动启用 CUDA repo override。
- `stage2` 不再内置发行版特例；NVIDIA 细节交给本安装器探测和交互/脚本参数决定。

## 脚本化示例

```bash
bash ~/my-linux-setup/drivers/nvidia/install-nvidia-cuda.sh \
  --apply \
  --method deb \
  --cuda latest \
  --driver-branch latest \
  --install-toolkit
```

## 文件

- `install-nvidia-cuda.sh` — 主安装器
- `probe_nvidia_metadata.py` — 官方元数据解析
- `10-nvidia-driver-cuda.original.sh` — 原始命令参考
- `cuda-keyring_1.1-1_all.deb` — 本地 keyring 包副本
