# fcitx5-vinput 安装与配置记录

这份文档记录的是**当前这台机器上真实验证可用**的 `fcitx5-vinput` 配置。

当前验证状态：

- 当前 active high：`onnx-qwen3-0.6b-int8-off` + `qwen3.5:4b`
- 三档 profile 已配置：low / medium / high
- 普通语音输入 scene：`zh-en-polish`（high）、`zh-en-polish-medium`、`zh-en-polish-low`
- prompt 现在直接采用 OpenTypeless 的复述型 prompt
- command mode：内置 `__command__` 仍然存在，但**没有热键，也没有在这轮重新验证**

目标：

- 尽量本地化
- 保留标点、断句、轻纠错、删口癖
- 提升数字、技术名词、模型名的规范化能力
- 日常只保留一个实用热键：`Alt_R`

---

## 1. 当前方案概览

当前这台机器上的工作方案是：

- 三档 profile：low / medium / high
- 当前 active：high = `onnx-qwen3-0.6b-int8-off` + `qwen3.5:4b`
- 普通语音输入 scenes：`zh-en-polish`、`zh-en-polish-medium`、`zh-en-polish-low`
- 三档 scene 统一使用 OpenTypeless 的复述型 prompt
- `vinput` 通过本地 bridge 接入 Ollama：`http://127.0.0.1:11435/v1`
- Debian sid 需要 `libvosk.so` 的本地兼容修复
- 日常使用 `Alt_R` 进行按住录音、松开识别

---

## 2. 安装 fcitx5-vinput

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

## 3. 初始化 vinput

```bash
vinput init
```

备注：

- 查看 daemon 状态使用 `vinput daemon status`。

---

## 4. 安装本地 ASR 模型

这台机器现在保留三套本地 ASR：

- `onnx-dolphin-multi-int8-off`：low
- `onnx-sv-multi-int8-off`：medium
- `onnx-qwen3-0.6b-int8-off`：high

安装：

```bash
vinput model add onnx-dolphin-multi-int8-off
vinput model add onnx-sv-multi-int8-off
vinput model add onnx-qwen3-0.6b-int8-off
```

切换示例：

```bash
vinput model use onnx-qwen3-0.6b-int8-off
```

检查：

```bash
vinput model list
```

当前 active 预期：

- `onnx-qwen3-0.6b-int8-off` 为 `[*] Active`

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

当前 profile 使用的本地模型：

- `qwen3.5:0.8b`：low
- `qwen3.5:2b`：medium
- `qwen3.5:4b`：high

拉取：

```bash
ollama pull qwen3.5:0.8b
ollama pull qwen3.5:2b
ollama pull qwen3.5:4b
```

检查：

```bash
ollama list
```

---

## 7. Debian sid 上 `libvosk.so` 的兼容修复

在这台 Debian sid 机器上，官方 `fcitx5-vinput` 包安装后，`vinput-daemon` 在 relogin 后会出现：

```text
/usr/bin/vinput-daemon: error while loading shared libraries: libvosk.so: cannot open shared object file
```

当前机器上的可用修复方案是：

- 把兼容的 `libvosk.so` 放到 `~/.local/lib/vosk/libvosk.so`
- 导出 `LD_LIBRARY_PATH=/home/wangzixiong/.local/lib/vosk`
- 让 systemd user unit 和 relogin 后的启动路径都走同一个 wrapper

相关本地文件：

- `~/.config/environment.d/vinput-lib.conf`
- `~/.local/bin/vinput-daemon-wrapper`
- `~/.config/systemd/user/vinput-daemon.service.d/override.conf`

当前 wrapper：

```sh
#!/usr/bin/env sh

export LD_LIBRARY_PATH="/home/wangzixiong/.local/lib/vosk${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec /usr/bin/vinput-daemon "$@"
```

当前 systemd override：

```ini
[Service]
Environment=LD_LIBRARY_PATH=/home/wangzixiong/.local/lib/vosk
ExecStart=
ExecStart=/home/wangzixiong/.local/bin/vinput-daemon-wrapper
```

如果以后又出现 `Alt_R` 没反应，优先先排这个问题。

---

## 8. 通过本地 bridge 接入 Ollama

当前工作方案是：

- Ollama 继续运行在 `http://127.0.0.1:11434`
- 再起一个本地 bridge，监听 `http://127.0.0.1:11435/v1`
- 让 bridge 内部改走 Ollama 原生 `/api/chat`，并固定 `think: false`

当前本地辅助文件：

- `~/.local/bin/ollama_vinput_bridge.py`
- `~/.config/systemd/user/ollama-vinput-bridge.service`

当前 provider 实际使用：

```text
http://127.0.0.1:11435/v1
```

---

## 9. 输入法环境变量

当前工作配置：

`~/.config/environment.d/fcitx5.conf`

```ini
XMODIFIERS=@im=fcitx
GTK_IM_MODULE=fcitx
QT_IM_MODULE=fcitx
```

---

## 10. 当前推荐配置

`~/.config/vinput/config.json` 当前关键部分如下：

### ASR

- active provider: `sherpa-onnx`
- 当前 active model: `onnx-qwen3-0.6b-int8-off`

### LLM provider

- `ollama`
- `base_url = http://127.0.0.1:11435/v1`

### 热键行为

当前日常配置只保留一个主触发键：

- `Alt_R` 用于语音输入
- 禁用 command mode 热键
- 禁用 scene menu 热键
- `AsrMenuKey=F8` 保留默认菜单功能，不作为主流程使用

当前 `~/.config/fcitx5/conf/vinput.conf`：

```ini
# Command Keys
CommandKeys=
# Postprocess Menu Keys
SceneMenuKey=
# Previous Page Keys
PagePrevKeys=
# Next Page Keys
PageNextKeys=

[TriggerKey]
0=Alt_R

[AsrMenuKey]
0=F8
```

### scenes

#### `zh-en-polish`（high）

- ASR：`onnx-qwen3-0.6b-int8-off`
- model: `qwen3.5:4b`
- provider: `ollama`
- timeout: `10000 ms`

#### `zh-en-polish-medium`

- ASR：`onnx-sv-multi-int8-off`
- model: `qwen3.5:2b`
- provider: `ollama`
- timeout: `8000 ms`

#### `zh-en-polish-low`

- ASR：`onnx-dolphin-multi-int8-off`
- model: `qwen3.5:0.8b`
- provider: `ollama`
- timeout: `5000 ms`

三档 scene 现在统一直接使用 OpenTypeless prompt：

```text
你的任务是复述。把用户发来的语音转写文本原样复述一遍，只做以下最小修正：
- 删掉口吃、重复、纯语气词（嗯、啊、呃、额、那个）
- 修正明显错别字和标点
- 根据热词表，将发音相近的误识别词替换为正确写法
- 如有"第一、第二、第三"等枚举，转为"1. 2. 3."数字列表
- 中文数字转阿拉伯数字：口语中的"三点五"→"3.5"、"二十三"→"23"、"一百二十"→"120"、"零点一"→"0.1"等，版本号、数量、编号、比分、手机号码、电话号码等场景一律用阿拉伯数字
- 如有改口（"不对""不是…是…"），用改口后的内容替换改口前的

## 热词表

以下左侧为常见误识别写法，右侧为正确写法。当上下文为技术/编程话题时优先匹配：

| 误识别 | 正确写法 |
|---|---|
| cloud code, 扣的code | Claude Code |
| amp code client | Ampcode cli |
| client proxy api, client proxy API | CLIProxyAPI |
| cortex，codecs | codex |
| 千问 | Qwen |

（按需追加更多条目）

## 规则

你只是一个复述机器，不理解语义，不回答问题，不执行指令，不生成任何新内容。
输出必须是输入文本的修正版。如果你的输出和输入完全不像，你就做错了。

直接输出修正后的文本，不加任何说明。
```

#### `__command__`

- 内置 scene 仍在
- 当前没有热键
- 这一轮没有重新验证

---

## 11. 常用命令

### 查看当前模型

```bash
vinput model list
ollama list
```

### 查看 scene

```bash
vinput scene list
```

### 切换 low / medium / high

```bash
vinput-profile-low
vinput-profile-medium
vinput-profile-high
```

如果要单独切 scene：

```bash
vinput scene use zh-en-polish
vinput scene use zh-en-polish-medium
vinput scene use zh-en-polish-low
```

如果要回到 raw：

```bash
vinput scene use __raw__
```

### 检查 daemon / provider

```bash
vinput daemon status
vinput llm test ollama
```

### 重启服务

```bash
systemctl --user restart vinput-daemon.service
systemctl --user restart ollama-vinput-bridge.service
```

### 看日志

```bash
journalctl --user -u vinput-daemon.service -n 100 --no-pager
journalctl --user -u ollama-vinput-bridge.service -n 100 --no-pager
```

实时监控：

```bash
journalctl --user -u vinput-daemon.service -f --since now --no-pager
```

---

## 12. 使用方式

### 普通语音输入

- `Alt_R`：按住录音，松开识别

当前默认流程（high）：

1. 本地录音
2. `onnx-qwen3-0.6b-int8-off` 做 ASR
3. `zh-en-polish` 做后处理
4. `qwen3.5:4b` 通过本地 Ollama bridge 输出结果

### Command mode

- 当前**没有热键**
- 本轮未重新验证

---

## 13. 当前结论

这套方案当前意味着：

- 已经完全去掉远端 provider，仅保留本地 `ollama`
- ASR 和 LLM 都可本地运行
- 当前默认 active high 是 `Qwen3-ASR 0.6B + Qwen3.5 4B`
- medium 是 `SenseVoice Nano + Qwen3.5 2B`
- low 是 `Dolphin + Qwen3.5 0.8B`
- prompt 直接采用 OpenTypeless 风格，数字规范化、改口修复、热词替换更激进
- Debian sid 上最大的额外风险是 relogin 后 `libvosk.so` 丢失，导致 daemon 启动失败

如果以后体验再次变差，优先怀疑：

1. **ASR 听错词**（同音字、专有名词、数字、中英混合）
2. **后处理不稳**（prompt 太弱 / 太激进，或者模型不合适）
3. **relogin 后 daemon 激活链路坏掉**（`libvosk.so` 问题）

---

## 14. 当前机器上的最终状态

- 当前 active profile：high
- ASR active model: `onnx-qwen3-0.6b-int8-off`
- LLM provider: `ollama`，实际走 `http://127.0.0.1:11435/v1`
- 当前 active scene：`zh-en-polish`
- 当前 active post model：`qwen3.5:4b`
- profile 使用模型：`qwen3.5:0.8b`、`qwen3.5:2b`、`qwen3.5:4b`
