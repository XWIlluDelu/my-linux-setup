# fcitx5-vinput Setup Notes

This document records a **working setup verified on the current machine** for `fcitx5-vinput`:

- Local ASR: `sense-voice-zh-en-int8`
- Local LLM post-processing: `Ollama + qwen3:1.7b`
- Normal voice input scene: `zh-polish`
- Command mode scene: `__command__`

Goals:

- keep everything local as much as possible
- acceptable Chinese dictation experience
- keep punctuation restoration, sentence segmentation, light correction, and filler-word removal
- keep command-mode text editing capability
- keep only one hotkey: `Alt_R`

---

## 1. Install fcitx5-vinput

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

## 2. Initialize vinput

```bash
vinput init
```

> Note: the current CLI may differ from the README. Older commands such as `vinput registry sync` may no longer exist.

---

## 3. Install the local ASR model

The validated local model is:

- `sense-voice-zh-en-int8`

Install it:

```bash
vinput model add sense-voice-zh-en-int8
vinput model use sense-voice-zh-en-int8
```

Check:

```bash
vinput model list
```

Expected result:

- `sense-voice-zh-en-int8` is `[*] Active`

---

## 4. Start the vinput daemon

```bash
systemctl --user enable --now vinput-daemon.service
systemctl --user restart vinput-daemon.service
```

Check:

```bash
systemctl --user status vinput-daemon.service --no-pager
vinput status
```

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

## 6. Pull local LLM models

Currently kept local models:

- `qwen3:1.7b`: current main model
- `qwen3:0.6b`: faster fallback model

Pull them:

```bash
ollama pull qwen3:1.7b
ollama pull qwen3:0.6b
```

Check:

```bash
ollama list
```

---

## 7. Add the local Ollama provider

```bash
vinput llm add ollama -u http://127.0.0.1:11434/v1
```

Check:

```bash
vinput llm list
```

Expected result:

- only `ollama` remains

---

## 8. Recommended final configuration

The important parts of `~/.config/vinput/config.json` are:

### ASR

- active provider: `sherpa-onnx`
- active model: `sense-voice-zh-en-int8`

### LLM provider

- `ollama`
- `base_url = http://127.0.0.1:11434/v1`

### Hotkey behavior

Final setup uses a **single-key mode**:

- keep only `Alt_R` for voice input
- disable command-mode hotkey
- disable scene-menu hotkey
- keep the default scene fixed to `zh-polish`

`~/.config/fcitx5/conf/vinput.conf`:

```ini
[TriggerKey]
0=Alt_R

[CommandKeys]

[SceneMenuKey]

[PagePrevKeys]

[PageNextKeys]
```

### Scenes

#### `zh-polish`

- model: `qwen3:1.7b`
- provider: `ollama`
- timeout: `4000 ms`
- purpose: normal Chinese voice-input post-processing

Prompt:

```text
/no_think 你是中文语音转写后处理器。请只做最小必要编辑：补全中文标点，恢复自然断句，修正明显识别错误，删除不影响原意的口癖、语气词和重复赘词（如“嗯”“啊”“呃”“那个”“就是”等）。不要扩写，不要改写语气，不要添加信息；若不确定，保留原文。
```

#### `__command__`

- model: `qwen3:1.7b`
- provider: `ollama`
- timeout: `8000 ms`
- purpose: spoken editing on selected text

Prompt:

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

## 9. Useful commands

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

Chinese post-processing:

```bash
vinput scene use zh-polish
```

Back to raw mode:

```bash
vinput scene use __raw__
```

### Restart the daemon

```bash
systemctl --user restart vinput-daemon.service
```

### View logs

```bash
journalctl --user -u vinput-daemon.service -n 100 --no-pager
```

Live logs:

```bash
journalctl --user -u vinput-daemon.service -f --since now --no-pager
```

---

## 10. Usage

### Normal voice input

- `Alt_R`: start / stop recording

Default pipeline:

1. local recording
2. `sense-voice-zh-en-int8` ASR
3. `zh-polish` post-processing

### Command mode

- currently **no hotkey is enabled**
- if needed later, enable it separately instead of mixing it with the single-key workflow

Useful examples:

- “delete the previous sentence”
- “make this sentence shorter”
- “remove what I said earlier”

---

## 11. Current conclusions

This setup currently means:

- all remote LLM providers have been removed; only local `ollama` remains
- both ASR and LLM can run locally
- `qwen3:1.7b` is the best quality/latency trade-off so far
- `qwen3:4b` is too slow for default post-processing
- `qwen3:0.6b` is faster but lower quality

If the experience is still poor later, suspect two main bottlenecks first:

1. **ASR hearing the wrong words** (homophones, proper nouns, numbers, code-switching)
2. **post-processing instability** (prompt too aggressive, or model too weak)

---

## 12. Final state on this machine

- ASR active model: `sense-voice-zh-en-int8`
- LLM provider: `ollama`
- `zh-polish`: `qwen3:1.7b`
- `__command__`: `qwen3:1.7b`
