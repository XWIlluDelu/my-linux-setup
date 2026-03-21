# GNOME 应用网格整理 — Agent 指令

> 本文件供 AI agent 阅读，指导其自动整理 GNOME 应用网格中的游离图标。

## 工作流程

1. **分析**：运行 `bash app-grid.sh --analyze`，获取 JSON 格式的当前 Dock、文件夹和游离图标列表
2. **规划**：根据下方用户偏好和分析结果，生成分类 JSON 文件
3. **应用**：运行 `bash app-grid.sh --apply --folders-json /tmp/folders.json`

## 分析输出格式

`--analyze` 输出 JSON 到 stdout（info 日志在 stderr）：

```json
{
  "dock": ["org.gnome.Nautilus.desktop", "firefox.desktop", ...],
  "folders": {
    "System": {
      "name": "System",
      "apps": ["org.gnome.Settings.desktop", ...]
    }
  },
  "orphans": [
    {"name": "Calculator", "desktop_id": "org.gnome.Calculator.desktop"},
    ...
  ]
}
```

## 分类 JSON 格式

`--apply --folders-json FILE` 接受的 JSON 格式：

```json
{
  "folders": [
    {
      "id": "System",
      "name": "System",
      "apps": [
        "org.gnome.Settings.desktop",
        "org.gnome.tweaks.desktop",
        "org.gnome.DiskUtility.desktop"
      ]
    },
    {
      "id": "Utilities",
      "name": "Utilities",
      "apps": [
        "org.gnome.Calculator.desktop",
        "org.gnome.TextEditor.desktop"
      ]
    }
  ]
}
```

- 不存在的 `.desktop` 文件会被自动跳过
- 应用后会输出剩余游离图标数量

## 用户分类偏好

以下是用户习惯的文件夹分类（agent 应以此为基础生成 JSON）：

### System — 系统设置/驱动/更新/安全

- 网络连接编辑器、磁盘工具、系统监视器、系统设置、GNOME Tweaks
- 软件源、驱动管理、更新管理器、语言支持、扩展管理器
- 电源统计、密钥管理（Seahorse）、系统日志、输入法配置

### Utilities — 日常小工具

- 计算器、字符映射表、时钟、文本编辑器、字体查看器
- 图片查看器（Loupe）、文档查看器（Papers）
- 帮助（Yelp）、htop、vim、mpv、info

### NVIDIA — GPU 开发调试工具

- nvidia-settings、Nsight Compute、Nsight Systems、NVVP
- 其他任何 NVIDIA/CUDA 相关的 `.desktop` 文件

### Fcitx — 输入法相关

- Fcitx5 主程序、配置工具、迁移工具、键盘布局查看器

## 注意事项

- 运行分析和应用都**不需要 sudo**（gsettings 操作用户级 dconf）
- 每次 `--apply` 会自动创建备份脚本到 `/tmp/app-grid-backup-*.sh`
- 安装/卸载应用后分类列表可能过时，应重新运行分析
- 文件夹排列顺序：System → Utilities → NVIDIA → Fcitx → 其余游离图标
