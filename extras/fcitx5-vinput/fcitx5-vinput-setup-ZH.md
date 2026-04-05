# fcitx5-vinput 安装与配置记录

这份文档记录的是**当前这台机器上真实验证可用**的 `fcitx5-vinput` 配置。

当前验证状态：

- 本地 ASR：`onnx-sv-multi-int8-off`（`SenseVoice Nano`）
- 本地 LLM 后处理：`Ollama + qwen3.5:2b`
- 普通语音输入 scene：`zh-en-polish`
- command mode：内置 `__command__` 仍然存在，但**没有热键，也没有在这轮重新验证**

目标：

- 尽量本地化
- 保留标点、断句、轻纠错、删口癖
- 提升数字、技术名词、模型名的规范化能力
- 日常只保留一个实用热键：`Alt_R`

---

## 1. 这次和旧文档的主要差异

和旧版记录相比，这次有几处实质变化：

- 旧的 ASR 模型名 `sense-voice-zh-en-int8` 不再是这台机器上当前验证的方案；现在实际使用的是 `onnx-sv-multi-int8-off`（`SenseVoice Nano`）。
- 默认后处理模型从 `qwen3:1.7b` 换成了 `qwen3.5:2b`。
- 普通语音输入 scene 现在叫 `zh-en-polish`，不是旧文档里的 `zh-polish`。
- 这台机器上，`Qwen 3.5` 直接走 Ollama 的 `http://127.0.0.1:11434/v1` 并不稳定；现在改成先走本地 bridge：`http://127.0.0.1:11435/v1`。
- Debian sid 上官方 `.deb` 安装后的 `vinput-daemon` 在 relogin / D-Bus 激活路径里会丢 `libvosk.so`，需要做额外兼容修复。
- `fcitx5-vinput 2.0.12` 插件里的文案更接近“按住录音、松开识别”，比旧文档里“开始 / 结束录音”的说法更准确。

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

- 当前 CLI 和一些旧 README 示例不完全一致。
- `vinput registry sync` 这类旧命令可能已经不存在。
- 现在查看 daemon 状态应使用 `vinput daemon status`，旧文档里的 `vinput status` 已经过时。

---

## 4. 安装本地 ASR 模型

这台机器当前验证可用的是：

- `onnx-sv-multi-int8-off`

安装：

```bash
vinput model add onnx-sv-multi-int8-off
vinput model use onnx-sv-multi-int8-off
```

检查：

```bash
vinput model list
```

预期应看到：

- `onnx-sv-multi-int8-off` 为 `[*] Active`

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

- `qwen3.5:2b`：当前主力
- `qwen3.5:0.8b`：更轻量的备选
- `qwen3:1.7b`：旧的已验证回退模型
- `openbmb/minicpm4.1:latest`：测试过，但不建议作为默认

拉取：

```bash
ollama pull qwen3.5:2b
ollama pull qwen3.5:0.8b
ollama pull qwen3:1.7b
```

可选：

```bash
ollama pull openbmb/minicpm4.1
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

这台机器上，直接把 `vinput` 指到：

```text
http://127.0.0.1:11434/v1
```

在 `Qwen 3.5` 上并不稳定。测试里，Ollama 的 OpenAI-compatible 接口可能返回 reasoning-only 内容，最终正文为空。

当前稳定方案是：

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

现在不再依赖 `~/.profile` 里的重复 export。

---

## 10. 当前推荐配置

`~/.config/vinput/config.json` 当前关键部分如下：

### ASR

- active provider: `sherpa-onnx`
- active model: `onnx-sv-multi-int8-off`

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

### scene

#### `zh-en-polish`

- model: `qwen3.5:2b`
- provider: `ollama`
- timeout: `8000 ms`
- 用途：普通中文 / 中英混合语音输入后处理

当前 prompt：

```text
你是中英混合语音转写后处理器。只输出润色后的正文，不附加任何说明。

任务目标：在尽量保持原意、语气和措辞的前提下，对转写结果做最小必要修正。

处理以下问题：
- 标点与断句：补全中文标点；英文片段保留英文标点习惯；按语义自然分句。
- 口语噪声：删除不影响原意的语气词、口癖、重复赘词与明显停顿词（如“嗯”“啊”“呃”“那个”“就是”等）。
- 拼写规范化：数字优先使用阿拉伯数字；高频且明确的技术名词、模型名、产品名、缩写还原为通行写法（如“千问三点五”→“Qwen 3.5”，“open ai”→“OpenAI”）。
- 识别修正：对同音 / 近音误识别和高置信度漏词做最小必要补全；把握不足则保留原文。

禁止：
- 扩写或补充原文没有的信息
- 解释、评论或重复原文
- 将口语随意改写成更正式的书面语
- 在把握不足时强行猜测
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

### 切换默认 scene

普通语音后处理：

```bash
vinput scene use zh-en-polish
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

当前默认流程：

1. 本地录音
2. `onnx-sv-multi-int8-off` 做 ASR
3. `zh-en-polish` 做后处理
4. `qwen3.5:2b` 通过本地 Ollama bridge 输出结果

### Command mode

- 当前**没有热键**
- 本轮未重新验证

---

## 13. 当前结论

这套方案当前意味着：

- 已经完全去掉远端 provider，仅保留本地 `ollama`
- ASR 和 LLM 都可本地运行
- `qwen3.5:2b` 是这台机器上目前质量 / 延迟最均衡的默认方案
- `qwen3.5:0.8b` 更轻，但规范化和纠错稳定性更弱
- `openbmb/minicpm4.1` 虽然能本地运行，但不适合作为默认后处理模型
- Debian sid 上最大的额外风险是 relogin 后 `libvosk.so` 丢失，导致 daemon 启动失败

如果以后体验再次变差，优先怀疑：

1. **ASR 听错词**（同音字、专有名词、数字、中英混合）
2. **后处理不稳**（prompt 太弱 / 太激进，或者模型不合适）
3. **relogin 后 daemon 激活链路坏掉**（`libvosk.so` 问题）

---

## 14. 当前机器上的最终状态

- ASR active model: `onnx-sv-multi-int8-off`
- LLM provider: `ollama`，实际走 `http://127.0.0.1:11435/v1`
- 普通语音 scene：`zh-en-polish`
- 默认后处理模型：`qwen3.5:2b`
- 本地保留回退模型：`qwen3.5:0.8b`、`qwen3:1.7b`
