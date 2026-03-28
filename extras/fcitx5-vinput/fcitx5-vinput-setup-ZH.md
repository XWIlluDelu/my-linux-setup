# fcitx5-vinput 安装与配置记录

这份文档记录的是一套**已在当前机器上验证可用**的 `fcitx5-vinput` 安装与配置流程：

- 本地 ASR：`sense-voice-zh-en-int8`
- 本地 LLM 后处理：`Ollama + qwen3:1.7b`
- 普通语音输入：`zh-polish`
- command mode：`__command__`

目标：

- 尽量本地化
- 中文输入体验可接受
- 保留标点、断句、轻纠错、删口癖
- 保留 command mode 文本编辑能力
- 只保留一个热键：`Alt_R`

---

## 1. 安装 fcitx5-vinput

按发行版安装即可。

### Arch Linux

```bash
yay -S fcitx5-vinput-bin
```

### Fedora

```bash
sudo dnf copr enable xifan/fcitx5-vinput-bin
sudo dnf install fcitx5-vinput
```

### Ubuntu 24.04

```bash
sudo add-apt-repository ppa:xifan233/ppa
sudo apt update
sudo apt install fcitx5-vinput
```

### 其他 Ubuntu / Debian

到 releases 页面下载 `.deb`：

- <https://github.com/xifan2333/fcitx5-vinput/releases>

然后安装：

```bash
sudo dpkg -i fcitx5-vinput_*.deb
sudo apt-get install -f
```

---

## 2. 初始化 vinput

```bash
vinput init
```

> 备注：当前版本 CLI 和 README 可能有出入。旧文档里的 `vinput registry sync` 等命令不一定可用。

---

## 3. 安装本地 ASR 模型

当前验证可用的是：

- `sense-voice-zh-en-int8`

安装：

```bash
vinput model add sense-voice-zh-en-int8
vinput model use sense-voice-zh-en-int8
```

检查：

```bash
vinput model list
```

预期应看到：

- `sense-voice-zh-en-int8` 为 `[*] Active`

---

## 4. 启动 vinput daemon

```bash
systemctl --user enable --now vinput-daemon.service
systemctl --user restart vinput-daemon.service
```

检查：

```bash
systemctl --user status vinput-daemon.service --no-pager
vinput status
```

---

## 5. 安装 Ollama

Linux 官方安装：

```bash
curl -fsSL https://ollama.com/install.sh | sh
```

检查：

```bash
ollama --version
systemctl status ollama --no-pager
curl http://127.0.0.1:11434/api/tags
```

---

## 6. 拉取本地 LLM 模型

当前保留的本地模型：

- `qwen3:1.7b`：当前主力
- `qwen3:0.6b`：备选更快模型

拉取：

```bash
ollama pull qwen3:1.7b
ollama pull qwen3:0.6b
```

检查：

```bash
ollama list
```

---

## 7. 添加本地 Ollama provider

```bash
vinput llm add ollama -u http://127.0.0.1:11434/v1
```

检查：

```bash
vinput llm list
```

预期只保留：

- `ollama`

---

## 8. 当前推荐配置

当前机器上的 `~/.config/vinput/config.json` 关键部分如下：

### ASR

- active provider: `sherpa-onnx`
- active model: `sense-voice-zh-en-int8`

### LLM provider

- `ollama`
- `base_url = http://127.0.0.1:11434/v1`

### scenes

#### 热键行为

最终采用的是**单键模式**：

- 仅保留 `Alt_R` 作为语音输入键
- 禁用 command mode 热键
- 禁用 scene menu 热键
- 默认 scene 固定为 `zh-polish`

对应的 `~/.config/fcitx5/conf/vinput.conf`：

```ini
[TriggerKey]
0=Alt_R

[CommandKeys]

[SceneMenuKey]

[PagePrevKeys]

[PageNextKeys]
```

#### `zh-polish`

- model: `qwen3:1.7b`
- provider: `ollama`
- timeout: `4000 ms`
- 用途：普通中文语音输入后处理

prompt：

```text
/no_think 你是中文语音转写后处理器。请只做最小必要编辑：补全中文标点，恢复自然断句，修正明显识别错误，删除不影响原意的口癖、语气词和重复赘词（如“嗯”“啊”“呃”“那个”“就是”等）。不要扩写，不要改写语气，不要添加信息；若不确定，保留原文。
```

#### `__command__`

- model: `qwen3:1.7b`
- provider: `ollama`
- timeout: `8000 ms`
- 用途：选中文本后口头编辑

prompt：

```text
/no_think
# Command Mode Prompt

## Role

You are an assistant that applies a spoken command to the user-provided text.

## Context

- The user message is the source text to operate on.
- The spoken command may contain ASR errors.
- The spoken command is appended at runtime in the `## Task` section.

## Rules

- Apply the spoken command directly to the source text.
- Do not add new information.
- Keep untouched parts unchanged.
- If deletion leaves dangling connectors or broken phrasing, clean them up minimally.

## Task
```

---

## 9. 常用命令

### 查看当前模型

```bash
vinput model list
ollama list
```

### 查看 scene

```bash
vinput scene list
```

### 切换默认 scene

普通语音输入后处理：

```bash
vinput scene use zh-polish
```

如果要回到 raw：

```bash
vinput scene use __raw__
```

### 重启 daemon

```bash
systemctl --user restart vinput-daemon.service
```

### 看日志

```bash
journalctl --user -u vinput-daemon.service -n 100 --no-pager
```

实时监控：

```bash
journalctl --user -u vinput-daemon.service -f --since now --no-pager
```

---

## 10. 使用方式

### 普通语音输入

- `Alt_R`：开始 / 结束录音

默认流程：

1. 本地录音
2. `sense-voice-zh-en-int8` 做 ASR
3. `zh-polish` 做后处理

### Command mode

- 当前**没有热键**
- 如需临时启用，建议后续单独再配，不与单键语音输入混用

适合：

- “删掉上一句”
- “把这句话改短一点”
- “删掉我之前说的那句话”

---

## 11. 当前结论

这套方案的特点：

- 已经完全去掉远端 provider，仅保留本地 `ollama`
- ASR 和 LLM 都可本地运行
- `qwen3:1.7b` 是当前质量 / 延迟比较均衡的方案
- `qwen3:4b` 明显更慢，不适合作为默认后处理
- `qwen3:0.6b` 更快，但质量上限更低

如果后续体验还差，优先怀疑两点：

1. **ASR 听错词**（同音字、专有名词、数字、中英混合）
2. **后处理过度或不稳**（可再继续缩 prompt 或换模型）

---

## 12. 当前机器上的最终状态（保存本文档时）

- ASR active model: `sense-voice-zh-en-int8`
- LLM provider: `ollama`
- `zh-polish`: `qwen3:1.7b`
- `__command__`: `qwen3:1.7b`
