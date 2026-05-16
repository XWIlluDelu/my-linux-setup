# my-linux-setup

Linux 装机、更新、维护脚本集。默认仓库路径：`~/my-linux-setup`。

## 安全模型

- 默认都是预览模式：脚本默认 `--check`，只有显式传 `--apply` 才会改系统。
- `setup stage1` 会转换 Btrfs 子卷布局并自动重启；不要和 `stage2` 连跑。
- `setup stage2` 面向 Debian/Ubuntu + Btrfs root；部分底层 task 支持 apt/dnf/zypper/pacman，但完整装机流不等于跨发行版通用。
- `extras/` 是独立工具或故障记录，不接入 `manage.sh` 主流程。

## 主入口

```bash
bash ~/my-linux-setup/manage.sh --help
bash ~/my-linux-setup/manage.sh check
```

无参数运行 `manage.sh` 会打开交互菜单；有参数时按子命令分发。

| 命令 | 作用 |
|---|---|
| `setup stage1` | 转换 Btrfs root 为 `@rootfs` + `@home`，创建安全快照，重启 |
| `setup stage2` | 重启后初始化 snapper、移除 snap、升级系统、安装选定组件、cleanup |
| `update` / `update all` | 更新系统包，刷新已检测到的受管应用和 shell 组件，cleanup |
| `update packages` | 只运行系统包升级 |
| `update apps` | 刷新已检测到或交互选中的受管应用和 shell 组件 |
| `maintain repair` | 修复 Debian/Ubuntu 包状态并重建相关内核产物 |
| `maintain mirror` | 探测、切换或恢复 APT 镜像 |
| `snapshot create` | 创建只读 snapper 快照 |
| `snapshot rollback` | 用 snapper 创建启动级回滚目标 |
| `shell sync` | 只重写已受管 shell 配置文件 |
| `driver nvidia` | NVIDIA 驱动 + CUDA 独立安装器 |

## 装机流程

Stage 1：只在刚装完系统、确认 root 是 Btrfs 且 `/home` 不是独立挂载时执行。

```bash
bash ~/my-linux-setup/manage.sh setup stage1 --apply
```

系统重启后再执行 Stage 2：

```bash
bash ~/my-linux-setup/manage.sh setup stage2 --apply --profile desktop
bash ~/my-linux-setup/manage.sh setup stage2 --apply --profile server
```

Profile 默认项：

| 项 | `desktop` | `server` |
|---|---:|---:|
| shell 环境 | yes | yes |
| 桌面基础包 | yes | no |
| 中文输入/字体支持 | yes | no |
| VS Code | yes | no |
| Microsoft Edge | yes | no |
| NVIDIA 安装器 | yes | yes |
| Flatpak / WeChat / Clash Verge Rev / Zotero / Obsidian / Ghostty / Maple Font / Miniforge | no | no |

不加 `--yes` 时，`stage2 --apply` 会让用户确认 profile 和安装项。

## 更新与维护

完整例行更新：

```bash
bash ~/my-linux-setup/manage.sh update --apply
```

只升级系统包：

```bash
bash ~/my-linux-setup/manage.sh update packages --apply
```

刷新受管应用与 shell 组件：

```bash
bash ~/my-linux-setup/manage.sh update apps --apply
```

`update apps` 会先检测现有受管状态：已安装/已受管的 Edge、VS Code、Flatpak、WeChat、Clash Verge Rev、Zotero、Obsidian、Ghostty、Maple Font、Miniforge、shell 环境会被默认选中；有 TTY 时可交互增删选择，`--yes` 使用检测结果。

修复包状态：

```bash
bash ~/my-linux-setup/manage.sh maintain repair --apply
```

APT 镜像：

```bash
bash ~/my-linux-setup/manage.sh maintain mirror --list
bash ~/my-linux-setup/manage.sh maintain mirror --auto
bash ~/my-linux-setup/manage.sh maintain mirror --reset
```

## Shell 配置边界

受管文件：

- `~/.profile`
- `~/.bashrc`
- `~/.zshrc`
- `~/.config/starship.toml`

只重写这些文件：

```bash
bash ~/my-linux-setup/manage.sh shell sync --apply --profile desktop
bash ~/my-linux-setup/manage.sh shell sync --apply --profile server
```

`shell sync` 要求目标用户已经存在 linux-setup 受管 shell 状态。机器特有路径、手动安装的 Node.js、临时代理、SDK 路径、Miniforge shell hook 等不写进 `assets/`；本机恢复策略见 [`LOCAL_ENV_AGENT_NOTES.md`](LOCAL_ENV_AGENT_NOTES.md)。

## 快照

```bash
bash ~/my-linux-setup/manage.sh snapshot create --apply
bash ~/my-linux-setup/manage.sh snapshot rollback --apply --snapshot <N>
```

`rollback` 默认会重启；如只创建回滚目标不重启，传 `--no-reboot`。

## NVIDIA

```bash
bash ~/my-linux-setup/manage.sh driver nvidia --check
bash ~/my-linux-setup/manage.sh driver nvidia --apply
```

模块说明见 [`drivers/nvidia/README.md`](drivers/nvidia/README.md)。

## Extras

| 目录 | 内容 |
|---|---|
| `extras/app-grid/` | GNOME 应用网格分析与文件夹整理 |
| `extras/fcitx5-vinput/` | `fcitx5-vinput` 本机配置记录 |
| `extras/ghostty-default-terminal/` | GNOME `xdg-terminal-exec` 默认终端设置 |
| `extras/nautilus-enhancements/` | Nautilus `Open in Terminal` 与 `Copy Path` 增强 |
| `extras/psychtoolbox/` | Psychtoolbox 3 本机安装记录 |
| `extras/wemeet-screen-share-fix/` | Wemeet 共享屏幕黑屏修复记录 |
| `extras/zeabur/` | Zeabur 服务器 VPS 化记录 |
| `extras/my-ai-tools/` | 独立本地/远端辅助工具记录 |
