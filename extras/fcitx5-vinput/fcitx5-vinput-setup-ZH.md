# fcitx5-vinput 安装与配置记录

本文件记录这台机器上验证过的 `fcitx5-vinput` 本地语音输入方案。

## 目标状态

| 层 | 配置 |
|---|---|
| 主触发键 | `Alt_R` 按住录音，松开识别 |
| ASR provider | `sherpa-onnx` |
| LLM provider | `ollama` |
| Ollama bridge | `http://127.0.0.1:11435/v1` |
| Ollama native endpoint | `http://127.0.0.1:11434` |
| 主 scene | `zh-en-polish` |
| fcitx5-vinput 版本 | `2.2.2` |
| Ollama 热加载 | Bridge 请求设置 `keep_alive=30m`；user timer 每 20 分钟刷新当前 scene 模型 |
| Command mode | 内置 `__command__` 保留，但不绑定热键 |

三档 profile：

| Profile | ASR | LLM | Timeout |
|---|---|---|---:|
| high | `onnx-qwen3-0.6b-int8-off` | `qwen3.5:4b` | `10000 ms` |
| medium | `onnx-zf-zh-en-off` | `qwen3.5:2b` | `8000 ms` |
| low | `onnx-sv-multi-int8-off` | `qwen3.5:0.8b` | `5000 ms` |

三档 scene 均使用纯 OpenTypeless 基础 prompt；回退前的激进定制 prompt 备份在 [`customized-pre-rollback-prompt.md`](customized-pre-rollback-prompt.md)。

## 安装

### fcitx5-vinput

```bash
# Arch
 yay -S fcitx5-vinput-bin

# Fedora
sudo dnf copr enable xifan/fcitx5-vinput-bin
sudo dnf install fcitx5-vinput

# Ubuntu 24.04
sudo add-apt-repository ppa:xifan233/ppa
sudo apt update
sudo apt install fcitx5-vinput
```

其他 Debian/Ubuntu 版本从 <https://github.com/xifan2333/fcitx5-vinput/releases> 下载 `.deb`：

```bash
sudo dpkg -i fcitx5-vinput_*.deb
sudo apt-get install -f
```

初始化：

```bash
vinput init
vinput daemon status
```

### ASR 模型

```bash
vinput model add onnx-sv-multi-int8-off
vinput model add onnx-zf-zh-en-off
vinput model add onnx-qwen3-0.6b-int8-off
vinput model use onnx-qwen3-0.6b-int8-off
vinput model list
```

### Ollama 与本地 LLM

```bash
curl -fsSL https://ollama.com/install.sh | sh
ollama pull qwen3.5:0.8b
ollama pull qwen3.5:2b
ollama pull qwen3.5:4b
ollama list
```

## Debian sid `libvosk.so` 修复

故障特征：

```text
/usr/bin/vinput-daemon: error while loading shared libraries: libvosk.so: cannot open shared object file
```

本机修复方案：

- 兼容库：`~/.local/lib/vosk/libvosk.so`
- systemd override：`~/.config/systemd/user/vinput-daemon.service.d/override.conf`
- 历史 wrapper：`~/.local/bin/vinput-daemon-wrapper` 仍存在，但当前 systemd unit 未使用它
- `~/.config/environment.d/vinput-lib.conf` 当前不存在

Override 内容：

```ini
[Service]
Environment=LD_LIBRARY_PATH=/home/wangzixiong/.local/lib/vosk
```

## Ollama bridge

`vinput` 使用 OpenAI-compatible endpoint，但 bridge 内部调用 Ollama 原生 `/api/chat`，固定 `think: false`，并设置 `keep_alive` 让后处理模型常驻。

本机文件：

- `~/.local/bin/ollama_vinput_bridge.py`
- `~/.config/systemd/user/ollama-vinput-bridge.service`
- `~/.local/bin/vinput-warm-ollama`
- `~/.config/systemd/user/vinput-warm-ollama.service`
- `~/.config/systemd/user/vinput-warm-ollama.timer`

Provider endpoint：

```text
http://127.0.0.1:11435/v1
```

Bridge 仍然必要：直接请求 Ollama `/v1/chat/completions` 时，`qwen3.5` 可能返回空 `content`；bridge 走原生 `/api/chat`，再返回 `vinput` 需要的 message content。

热加载策略：

- `ollama-vinput-bridge.service` 设置 `OLLAMA_KEEP_ALIVE=30m`。
- `vinput-warm-ollama.timer` 每 20 分钟运行一次。
- `vinput-warm-ollama` 从 `~/.config/vinput/config.json` 读取当前 active scene，并预热该 scene 配置的模型。

## 输入法环境

`~/.config/environment.d/fcitx5.conf`：

```ini
XMODIFIERS=@im=fcitx
QT_IM_MODULE=fcitx
```

本机没有设置 `GTK_IM_MODULE`；GTK 在 GNOME/Wayland 下按桌面默认路径处理。

`~/.config/fcitx5/conf/vinput.conf` 关键项：

```ini
CommandKeys=
SceneMenuKey=
PagePrevKeys=
PageNextKeys=

[TriggerKey]
0=Alt_R

[AsrMenuKey]
0=F8
```

## 常用命令

```bash
vinput model list
vinput scene list
vinput-profile-low
vinput-profile-medium
vinput-profile-high
vinput scene use zh-en-polish
vinput scene use zh-en-polish-medium
vinput scene use zh-en-polish-low
vinput scene use __raw__
vinput daemon status
vinput llm test ollama
systemctl --user status vinput-warm-ollama.timer
systemctl --user start vinput-warm-ollama.service
systemctl --user list-timers --all | grep vinput-warm
ollama ps
systemctl --user restart vinput-daemon.service
systemctl --user restart ollama-vinput-bridge.service
journalctl --user -u vinput-daemon.service -n 100 --no-pager
journalctl --user -u ollama-vinput-bridge.service -n 100 --no-pager
journalctl --user -u vinput-daemon.service -f --since now --no-pager
```

## 故障优先级

1. ASR 听错词：同音字、专有名词、数字、中英混合。
2. 后处理延迟：先查 `ollama ps` 和 `vinput-warm-ollama.timer`；通常是模型冷启动。
3. 后处理不稳：prompt 与模型组合不合适。
4. daemon 激活失败：优先检查 `libvosk.so`、wrapper、systemd override、Ollama bridge。
