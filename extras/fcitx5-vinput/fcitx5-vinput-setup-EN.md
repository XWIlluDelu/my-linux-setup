# fcitx5-vinput Setup Notes

This document records the **current working setup verified on this machine** for `fcitx5-vinput`.

Current validated state:

- Local ASR: `onnx-sv-multi-int8-off` (`SenseVoice Nano`)
- Local LLM post-processing: `Ollama + qwen3.5:2b`
- Normal voice input scene: `zh-en-polish`
- Command mode scene: builtin `__command__` remains present, but no hotkey is enabled and it was **not revalidated** in this round

Goals:

- keep everything local as much as possible
- keep punctuation restoration, sentence segmentation, light correction, and filler-word removal
- improve normalization for numbers and technical names
- keep only one practical hotkey for day-to-day voice input: `Alt_R`

---

## 1. What Changed From The Older Notes

Compared with the older setup notes, the following points changed materially:

- The old ASR model name `sense-voice-zh-en-int8` is no longer the validated choice on this machine. The current active registry model is `onnx-sv-multi-int8-off` (`SenseVoice Nano`).
- The old default post-processing model `qwen3:1.7b` has been replaced by `qwen3.5:2b`.
- The normal scene id is now `zh-en-polish`, not `zh-polish`.
- Directly pointing `vinput` to `http://127.0.0.1:11434/v1` was not reliable with `Qwen 3.5` on this machine. A local OpenAI-compatible bridge on `http://127.0.0.1:11435/v1` is now used instead.
- On Debian sid, the official `.deb` package was missing a usable `libvosk.so` path for relogin / D-Bus activation. A local compatibility fix is required.
- The addon strings in `fcitx5-vinput 2.0.12` indicate `TriggerKey` is intended as **press and hold to record, release to recognize**, which is more accurate than the older "start / stop" wording.

---

## 2. Install fcitx5-vinput

Install according to your distro.

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

### Other Ubuntu / Debian versions

Download the latest `.deb` from:

- <https://github.com/xifan2333/fcitx5-vinput/releases>

Then install it:

```bash
sudo dpkg -i fcitx5-vinput_*.deb
sudo apt-get install -f
```

---

## 3. Initialize vinput

```bash
vinput init
```

Notes:

- The current CLI differs from some older README examples.
- Commands such as `vinput registry sync` may no longer exist.
- `vinput daemon status` is the current daemon status command; older notes using `vinput status` are outdated.

---

## 4. Install The Local ASR Model

The validated local ASR model on this machine is:

- `onnx-sv-multi-int8-off`

Install it:

```bash
vinput model add onnx-sv-multi-int8-off
vinput model use onnx-sv-multi-int8-off
```

Check:

```bash
vinput model list
```

Expected result:

- `onnx-sv-multi-int8-off` is `[*] Active`

---

## 5. Install Ollama

Official Linux install:

```bash
curl -fsSL https://ollama.com/install.sh | sh
```

Check:

```bash
ollama --version
systemctl status ollama --no-pager
curl http://127.0.0.1:11434/api/tags
```

---

## 6. Pull Local LLM Models

Currently kept local models:

- `qwen3.5:2b`: current main model
- `qwen3.5:0.8b`: lighter fallback
- `qwen3:1.7b`: older known-good fallback
- `openbmb/minicpm4.1:latest`: tested, but not the recommended default

Pull them:

```bash
ollama pull qwen3.5:2b
ollama pull qwen3.5:0.8b
ollama pull qwen3:1.7b
```

Optional:

```bash
ollama pull openbmb/minicpm4.1
```

Check:

```bash
ollama list
```

---

## 7. Debian sid Compatibility Fix For `libvosk.so`

On this Debian sid machine, the official `fcitx5-vinput` package did not reliably load `libvosk.so` after relogin. The symptom was:

```text
/usr/bin/vinput-daemon: error while loading shared libraries: libvosk.so: cannot open shared object file
```

The current working fix on this machine is:

- keep a compatible `libvosk.so` at `~/.local/lib/vosk/libvosk.so`
- export `LD_LIBRARY_PATH=/home/wangzixiong/.local/lib/vosk`
- force both the systemd user unit and the relogin path to use the same wrapper

Relevant local files:

- `~/.config/environment.d/vinput-lib.conf`
- `~/.local/bin/vinput-daemon-wrapper`
- `~/.config/systemd/user/vinput-daemon.service.d/override.conf`

Current wrapper:

```sh
#!/usr/bin/env sh

export LD_LIBRARY_PATH="/home/wangzixiong/.local/lib/vosk${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec /usr/bin/vinput-daemon "$@"
```

Current systemd override:

```ini
[Service]
Environment=LD_LIBRARY_PATH=/home/wangzixiong/.local/lib/vosk
ExecStart=
ExecStart=/home/wangzixiong/.local/bin/vinput-daemon-wrapper
```

If `Alt_R` stops working again after relogin, check this section first.

---

## 8. Use A Local OpenAI-Compatible Bridge For Ollama

Directly using:

```text
http://127.0.0.1:11434/v1
```

was not reliable with `Qwen 3.5` on this machine. In testing, Ollama's OpenAI-compatible endpoint could return reasoning-only output with empty final content for `Qwen 3.5`.

The current working approach is:

- keep Ollama on `http://127.0.0.1:11434`
- run a local bridge on `http://127.0.0.1:11435/v1`
- let the bridge call Ollama native `/api/chat` with `think: false`

Current local helper files:

- `~/.local/bin/ollama_vinput_bridge.py`
- `~/.config/systemd/user/ollama-vinput-bridge.service`

Current provider endpoint:

```text
http://127.0.0.1:11435/v1
```

---

## 9. Environment Variables

Current working input-method environment:

`~/.config/environment.d/fcitx5.conf`

```ini
XMODIFIERS=@im=fcitx
GTK_IM_MODULE=fcitx
QT_IM_MODULE=fcitx
```

This machine no longer relies on duplicate exports in `~/.profile`.

---

## 10. Recommended Final Configuration

The important parts of `~/.config/vinput/config.json` are:

### ASR

- active provider: `sherpa-onnx`
- active model: `onnx-sv-multi-int8-off`

### LLM Provider

- `ollama`
- `base_url = http://127.0.0.1:11435/v1`

### Hotkey Behavior

Current practical setup keeps only one main trigger:

- keep `Alt_R` for voice input
- disable command-mode hotkey
- disable scene-menu hotkey
- leave `AsrMenuKey=F8` at its default menu binding

`~/.config/fcitx5/conf/vinput.conf` currently looks like:

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

### Scene

#### `zh-en-polish`

- model: `qwen3.5:2b`
- provider: `ollama`
- timeout: `8000 ms`
- purpose: normal Chinese / mixed Chinese-English voice-input post-processing

Prompt:

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

- builtin scene is still present
- no hotkey is enabled for it
- this path was **not revalidated** in the current round

---

## 11. Useful Commands

### Check current models

```bash
vinput model list
ollama list
```

### Check scenes

```bash
vinput scene list
```

### Set the default scene

Normal post-processing:

```bash
vinput scene use zh-en-polish
```

Back to raw mode:

```bash
vinput scene use __raw__
```

### Check daemon / provider

```bash
vinput daemon status
vinput llm test ollama
```

### Restart services

```bash
systemctl --user restart vinput-daemon.service
systemctl --user restart ollama-vinput-bridge.service
```

### View logs

```bash
journalctl --user -u vinput-daemon.service -n 100 --no-pager
journalctl --user -u ollama-vinput-bridge.service -n 100 --no-pager
```

Live logs:

```bash
journalctl --user -u vinput-daemon.service -f --since now --no-pager
```

---

## 12. Usage

### Normal voice input

- `Alt_R`: press and hold to record, release to recognize

Default pipeline:

1. local recording
2. `onnx-sv-multi-int8-off` ASR
3. `zh-en-polish` post-processing
4. `qwen3.5:2b` via the local Ollama bridge

### Command mode

- currently **no hotkey is enabled**
- not revalidated in this round

---

## 13. Current Conclusions

This setup currently means:

- all remote LLM providers are removed; only local `ollama` remains
- both ASR and LLM run locally
- `qwen3.5:2b` is the best quality/latency trade-off so far on this machine
- `qwen3.5:0.8b` is lighter but less stable on normalization / correction
- `openbmb/minicpm4.1` can run locally, but was not good enough as the default post-processing model
- the main Debian sid-specific risk is `libvosk.so` not being available in the relogin / D-Bus activation path

If the experience becomes poor again later, suspect these first:

1. **ASR hearing the wrong words** (homophones, proper nouns, numbers, code-switching)
2. **post-processing instability** (prompt too weak / too aggressive, or model mismatch)
3. **daemon activation path breaking after relogin** (`libvosk.so` issue)

---

## 14. Final State On This Machine

- ASR active model: `onnx-sv-multi-int8-off`
- LLM provider: `ollama` via `http://127.0.0.1:11435/v1`
- normal scene: `zh-en-polish`
- normal model: `qwen3.5:2b`
- fallback models kept locally: `qwen3.5:0.8b`, `qwen3:1.7b`
