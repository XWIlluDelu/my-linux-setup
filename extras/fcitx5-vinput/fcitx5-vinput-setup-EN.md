# fcitx5-vinput Setup Notes

This file records the validated local `fcitx5-vinput` voice-input setup. Credentials remain only in `~/.config/vinput/config.json`; do not commit them.

## Target state

| Layer | Configuration |
|---|---|
| Main trigger | Hold `Alt_R` to record, release to recognize |
| fcitx5-vinput | `2.3.3` |
| Active ASR provider | `provider.stepfun.streaming` with `stepaudio-2.5-asr-stream` |
| Local ASR fallback | `sherpa-onnx` with `onnx-qwen3-0.6b-int8-off` |
| Active LLM provider | `stepfun-v1` at `https://api.stepfun.com/v1` |
| Active scene | `zh-en-polish-stepfun` with `step-1o-turbo-vision` |
| Local LLM fallback | Ollama bridge at `http://127.0.0.1:11435/v1` |
| Ollama native endpoint | `http://127.0.0.1:11434` |
| Output ducking | Disabled; it requires WirePlumber when enabled |
| Command mode | Custom `__command__` scene, with no hotkey |

The command scene uses the current `<vinput-selected>` and `<vinput-asr>` input tags. Keep it unchanged: the v2.3.2 migration only replaces stock or legacy command prompts.

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

v2.3.3 routes D-Bus activation through `vinput-daemon.service` and adds optional output ducking. Keep the current `default` capture device and `Alt_R` trigger; recent upstream releases fix PipeWire-default-device handling and GNOME/Wayland trigger auto-repeat.

## ASR and scenes

Install the local fallback models:

```bash
vinput model add onnx-sv-multi-int8-off
vinput model add onnx-zf-zh-en-off
vinput model add onnx-qwen3-0.6b-int8-off
vinput model use onnx-qwen3-0.6b-int8-off
```

`provider.stepfun.streaming` is a machine-local command provider, not a standard vinput-registry entry. Its script is `~/.local/share/vinput/providers/stepfun/streaming`; its registration lives in `~/.config/vinput/config.json`. The provider script and its credentials are deliberately not stored in this repository.

```bash
vinput provider use provider.stepfun.streaming
```

Set `VINPUT_ASR_API_KEY` only in the provider's `env` object. The configured provider also sets `VINPUT_ASR_MODEL=stepaudio-2.5-asr-stream`, `VINPUT_ASR_LANGUAGE=zh`, `VINPUT_ASR_ENABLE_ITN=true`, `VINPUT_ASR_FULL_RERUN_ON_COMMIT=true`, `VINPUT_ASR_FINISH_GRACE_SECS=5.0`, and `VINPUT_ASR_TIMEOUT=30`.

The current scenes are:

| Scene | ASR | LLM | Timeout |
|---|---|---|---:|
| `zh-en-polish-stepfun` | StepFun streaming | `step-1o-turbo-vision` | `5000 ms` |
| `zh-en-polish` | Sherpa-ONNX Qwen3-ASR 0.6B | `qwen3.5:4b` | `10000 ms` |
| `zh-en-polish-medium` | Zipformer Zh-En | `qwen3.5:2b` | `8000 ms` |
| `zh-en-polish-low` | SenseVoice Nano | `qwen3.5:0.8b` | `5000 ms` |

Configure the StepFun OpenAI-compatible LLM, then set its `api_key` through the local editor. Do not pass a key on the command line or commit it:

```bash
vinput llm add stepfun-v1 --base-url https://api.stepfun.com/v1
vinput config edit core
vinput llm test stepfun-v1
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
vinput provider use provider.stepfun.streaming
vinput model list
vinput scene list
vinput scene use zh-en-polish-stepfun
vinput scene use zh-en-polish
vinput scene use zh-en-polish-medium
vinput scene use zh-en-polish-low
vinput scene use __raw__
vinput daemon status
vinput daemon restart
vinput llm test stepfun-v1
vinput llm test ollama
systemctl --user status vinput-daemon.service
systemctl --user status vinput-warm-ollama.timer
systemctl --user restart ollama-vinput-bridge.service
ollama ps
```
