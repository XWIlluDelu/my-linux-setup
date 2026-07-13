# fcitx5-vinput Setup Notes

This file records the validated local `fcitx5-vinput` voice-input setup.
Credentials remain only in `~/.config/vinput/config.json`; do not commit them.

## Target state

| Layer | Configuration |
|---|---|
| Main trigger | Hold `Alt_R` to record, release to recognize |
| fcitx5-vinput | `2.3.3` |
| Active ASR provider | `provider.bailian.streaming` with `qwen3-asr-flash-realtime` |
| ASR endpoint | `wss://dashscope.aliyuncs.com/api-ws/v1/realtime` |
| Local ASR fallback | `sherpa-onnx` with `model.sherpa-onnx.qwen3-asr-0.6b-int8` |
| Active LLM provider | `bailian` at `https://dashscope.aliyuncs.com/compatible-mode/v1` |
| Active scene | `zh-en-polish-bailian` with `qwen-flash` |
| LLM options | `enable_thinking: false` |
| Local LLM fallback | Ollama bridge at `http://127.0.0.1:11435/v1` (`qwen3.5:2b`) |
| Ollama native endpoint | `http://127.0.0.1:11434` |
| Output ducking | Disabled; it requires WirePlumber when enabled |
| Command mode | `__command__` scene on Bailian `qwen-flash`, with no hotkey |

Use the generic DashScope endpoints above. Do not store workspace-only MaaS base URLs as the default.

## Why this stack

- Bailian realtime ASR provides partial text while speaking.
- Bailian `qwen-flash` is the low-cost polish model; disable thinking for latency.
- Local sherpa + Ollama remain as offline fallbacks.
- StepFun was previously used for streaming ASR and polish, but Plan endpoints do not provide the same realtime ASR path, and credit endpoints are not the default here.

## Install or upgrade

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

For a Debian or Ubuntu release without a suitable package source, download the matching v2.3.3 release asset from <https://github.com/xifan2333/fcitx5-vinput/releases/tag/v2.3.3>; do not install a package built for a different distribution release.

Initialize or refresh the service after an upgrade:

```bash
vinput init
systemctl --user enable --now vinput-daemon.service
fcitx5 -r
```

## ASR and scenes

Install the local fallback model:

```bash
vinput model add onnx-qwen3-0.6b-int8-off
vinput model use onnx-qwen3-0.6b-int8-off
```

Optional extra local models:

```bash
vinput model add onnx-sv-multi-int8-off
vinput model add onnx-zf-zh-en-off
```

`provider.bailian.streaming` is a machine-local command provider. Its script is:

```text
~/.local/share/vinput/providers/bailian/streaming
```

Registration and credentials live only in `~/.config/vinput/config.json`.

### Required secrets

Put the same Bailian API key in exactly two places:

1. ASR:

```text
asr.providers[provider.bailian.streaming].env.VINPUT_ASR_API_KEY
```

2. LLM:

```text
llm.providers[bailian].api_key
```

Do not put keys on the command line or in this repository.

### Active ASR env

```json
{
  "VINPUT_ASR_API_KEY": "<bailian-key>",
  "VINPUT_ASR_MODEL": "qwen3-asr-flash-realtime",
  "VINPUT_ASR_URL": "wss://dashscope.aliyuncs.com/api-ws/v1/realtime",
  "VINPUT_ASR_LANGUAGE": "zh",
  "VINPUT_ASR_TIMEOUT": "30",
  "VINPUT_ASR_FINISH_GRACE_SECS": "2.0"
}
```

### Active LLM provider

```json
{
  "id": "bailian",
  "base_url": "https://dashscope.aliyuncs.com/compatible-mode/v1",
  "api_key": "<bailian-key>",
  "extra_body": {
    "enable_thinking": false
  }
}
```

### Scenes

| Scene | Purpose | Provider / model | Timeout |
|---|---|---|---:|
| `zh-en-polish-bailian` | Default polish | Bailian `qwen-flash` | `10000 ms` |
| `zh-en-polish-local` | Offline polish fallback | Ollama `qwen3.5:2b` | `8000 ms` |
| `__raw__` | ASR only, no LLM | none | n/a |
| `__command__` | Spoken edit of selected text | Bailian `qwen-flash` | `10000 ms` |

```bash
vinput provider use provider.bailian.streaming
vinput scene use zh-en-polish-bailian
vinput llm test bailian
```

## Ollama fallback

```bash
curl -fsSL https://ollama.com/install.sh | sh
ollama pull qwen3.5:0.8b
ollama pull qwen3.5:2b
ollama pull qwen3.5:4b
```

`ollama_vinput_bridge.py` exposes the OpenAI-compatible endpoint at `11435`, calls Ollama native `/api/chat`, forces `think: false` for Qwen models, and keeps models resident for 30 minutes. `vinput-warm-ollama.timer` runs every 20 minutes and is a no-op while the active scene is not served by Ollama.

Machine-local files:

- `~/.local/bin/ollama_vinput_bridge.py`
- `~/.config/systemd/user/ollama-vinput-bridge.service`
- `~/.local/bin/vinput-warm-ollama`
- `~/.config/systemd/user/vinput-warm-ollama.service`
- `~/.config/systemd/user/vinput-warm-ollama.timer`

## Input-method environment

`~/.config/environment.d/fcitx5.conf`:

```ini
XMODIFIERS=@im=fcitx
QT_IM_MODULE=fcitx
```

GTK follows the GNOME/Wayland default path; this setup does not set `GTK_IM_MODULE`.

`~/.config/fcitx5/conf/vinput.conf`:

```ini
TriggerMode=Both
CommandKeys=
AsrMenuKey=
PagePrevKeys=
PageNextKeys=

[TriggerKey]
0=Alt_R

[SceneMenuKey]
0=F8
```

## Optional output ducking

v2.3.3 can lower system output while recording through WirePlumber. The current setup leaves it disabled. To enable it:

```bash
sudo apt install wireplumber
vinput config set /global/duck_output_while_recording true
vinput config set /global/duck_output_volume 0.25
```

## Useful commands

```bash
vinput provider list
vinput provider use provider.bailian.streaming
vinput model list
vinput scene list
vinput scene use zh-en-polish-bailian
vinput scene use zh-en-polish-local
vinput scene use __raw__
vinput daemon status
vinput daemon restart
vinput llm test bailian
vinput llm test ollama
systemctl --user status vinput-daemon.service
systemctl --user status vinput-warm-ollama.timer
systemctl --user restart ollama-vinput-bridge.service
ollama ps
journalctl --user -u vinput-daemon.service -f
```
