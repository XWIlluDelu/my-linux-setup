# my-linux-setup

自动化 Linux 装机与日常维护工具集。

默认仓库路径是 `~/my-linux-setup`。所有命令默认安全预览（`--check`），加 `--apply` 才会真正执行。

不要把 `stage1` 和 `stage2` 连着直接运行。`stage1` 会修改 Btrfs 布局并自动重启；等系统重启完成后，再单独运行 `stage2`。

## 推荐入口

主入口统一是 `manage.sh`。

## 额外脚本（extras）

`extras/` 下放的是独立工具，不接入 `manage.sh` 主流程，按需单独运行。

### Ghostty 默认终端

把 Ghostty 设为 GNOME 下的默认终端，按 `extras/ghostty-default-terminal/README.md` 中记录的最小步骤手动执行即可。

如果还想让 Nautilus 的 `Open in Terminal` 也打开 `ghostty`，以及给右键菜单增加 `Copy Path`，请看 `extras/nautilus-enhancements/README.md`。

### 装机流程

Stage 1：转换 Btrfs 布局并重启

```bash
bash ~/my-linux-setup/manage.sh setup stage1 --apply
```

Stage 2：重启后继续完成桌面装机

```bash
bash ~/my-linux-setup/manage.sh setup stage2 --apply
```

Stage 2（server）：只走 server profile

```bash
bash ~/my-linux-setup/manage.sh setup stage2 --apply --profile server
```

### 更新与维护

只重写托管 shell 配置文件：

```bash
bash ~/my-linux-setup/manage.sh shell sync --apply --profile desktop
```

完整例行更新。这里会依次处理系统包更新、已受管应用与 shell 组件刷新，以及最后的 cleanup：

```bash
bash ~/my-linux-setup/manage.sh update --apply
```

只刷新已受管应用与 shell 组件。这里包含仓库路径下的 Edge、VSCode，也包含官方安装路径下的 WeChat、Ghostty、Miniforge 等：

```bash
bash ~/my-linux-setup/manage.sh update apps --apply
```

只运行系统包升级这一步：

```bash
bash ~/my-linux-setup/manage.sh update packages --apply
```

修复 Debian/Ubuntu 包状态：

```bash
bash ~/my-linux-setup/manage.sh maintain repair --apply
```

APT 镜像探测或切换：

```bash
bash ~/my-linux-setup/manage.sh maintain mirror --list
bash ~/my-linux-setup/manage.sh maintain mirror --auto
```

### 快照

手动创建快照：

```bash
bash ~/my-linux-setup/manage.sh snapshot create --apply
```

回滚到指定快照：

```bash
bash ~/my-linux-setup/manage.sh snapshot rollback --apply
```

### NVIDIA

交互式安装 NVIDIA 驱动和 CUDA：

```bash
bash ~/my-linux-setup/manage.sh driver nvidia --apply
```

更多说明见 [drivers/nvidia/README.md](drivers/nvidia/README.md)。
