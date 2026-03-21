# my-linux-setup

自动化 Linux 装机与日常维护工具集。

下面的命令示例默认仓库位于 `~/my-linux-setup`。
所有脚本默认安全预览（`--check`），加 `--apply` 才会真正执行。

不要把 `stage1` 和 `stage2` 连着直接运行。
`stage1` 会修改 Btrfs 布局并自动重启；等系统重启完成后，再单独运行 `stage2`。

## 主入口

### Stage 1：装机前（转换 Btrfs 布局）

作用：转换 Btrfs 布局，拆分 `@rootfs` / `@home`，然后自动重启。

```bash
bash ~/my-linux-setup/setup.sh stage1 --apply
```

### Stage 2：桌面装机

作用：重启后继续完成桌面装机流程。

```bash
bash ~/my-linux-setup/setup.sh stage2 --apply
```

### Stage 2 (server)：服务器装机

作用：重启后继续完成 server profile，不安装桌面默认应用。

```bash
bash ~/my-linux-setup/setup.sh stage2 --apply --profile server
```

如需完全非交互，使用：

```bash
bash ~/my-linux-setup/setup.sh stage2 --apply --profile server --yes
```

### Extra：只想重部署 shell 配置

作用：重新写入托管的 `.profile`、`.bashrc`、`.zshrc`、`.tmux.conf`、`starship.toml`。

```bash
bash ~/my-linux-setup/tools/deploy-shell-config.sh --apply
```

## 主要的更新与维护项

### 更新已安装的额外软件

作用：更新已受管的软件，例如 WeChat、Ghostty、Miniforge、Maple Font、Flatpak 应用等。

```bash
bash ~/my-linux-setup/setup.sh update --apply
```

### 交互式安装 NVIDIA

作用：按交互选择安装驱动和 CUDA。

```bash
bash ~/my-linux-setup/setup.sh nvidia --apply
```

如需先看探测结果，使用：

```bash
bash ~/my-linux-setup/setup.sh nvidia --check
```

### 例行系统维护

作用：更新系统、清理缓存和无用包、清理 Flatpak、检查是否需要重启。

```bash
bash ~/my-linux-setup/tools/system-maintain.sh --apply
```

## 快照工具

### 手动创建快照

作用：交互式输入快照描述，并创建只读快照。

```bash
bash ~/my-linux-setup/tools/create-snapshot.sh --apply
```

### 回滚到指定快照

作用：交互式选择回滚目标快照，并准备回滚启动项。

```bash
bash ~/my-linux-setup/tools/rollback.sh --apply
```
