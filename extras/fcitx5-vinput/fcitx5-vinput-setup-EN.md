# fcitx5-vinput Setup Notes

This file records the validated local `fcitx5-vinput` voice-input setup on this machine.

## Target state

| Layer | Configuration |
|---|---|
| Main trigger | Hold `Alt_R` to record, release to recognize |
| ASR provider | `sherpa-onnx` |
| LLM provider | `ollama` |
| Ollama bridge | `http://127.0.0.1:11435/v1` |
| Ollama native endpoint | `http://127.0.0.1:11434` |
| Main scene | `zh-en-polish` |
| Command mode | Builtin `__command__` remains present, with no hotkey |

Profiles:

| Profile | ASR | LLM | Timeout |
|---|---|---|---:|
| high | `onnx-qwen3-0.6b-int8-off` | `qwen3.5:4b` | `10000 ms` |
| medium | `onnx-zf-zh-en-off` | `qwen3.5:2b` | `8000 ms` |
| low | `onnx-sv-multi-int8-off` | `qwen3.5:0.8b` | `5000 ms` |

All three scenes use the pure OpenTypeless base prompt. The older aggressive custom prompt is backed up in [`customized-pre-rollback-prompt.md`](customized-pre-rollback-prompt.md).

## Install

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

For other Debian/Ubuntu versions, download the `.deb` from <https://github.com/xifan2333/fcitx5-vinput/releases>:

```bash
sudo dpkg -i fcitx5-vinput_*.deb
sudo apt-get install -f
```

Initialize:

```bash
vinput init
vinput daemon status
```

### ASR models

```bash
vinput model add onnx-sv-multi-int8-off
vinput model add onnx-zf-zh-en-off
vinput model add onnx-qwen3-0.6b-int8-off
vinput model use onnx-qwen3-0.6b-int8-off
vinput model list
```

### Ollama and local LLMs

```bash
curl -fsSL https://ollama.com/install.sh | sh
ollama pull qwen3.5:0.8b
ollama pull qwen3.5:2b
ollama pull qwen3.5:4b
ollama list
```

## Debian sid `libvosk.so` fix

Failure signature:

```text
/usr/bin/vinput-daemon: error while loading shared libraries: libvosk.so: cannot open shared object file
```

Machine-local fix:

- compatible library: `~/.local/lib/vosk/libvosk.so`
- systemd override: `~/.config/systemd/user/vinput-daemon.service.d/override.conf`
- historical wrapper: `~/.local/bin/vinput-daemon-wrapper` still exists, but the current systemd unit does not use it
- `~/.config/environment.d/vinput-lib.conf` is currently absent

Override:

```ini
[Service]
Environment=LD_LIBRARY_PATH=/home/wangzixiong/.local/lib/vosk
```

## Ollama bridge

`vinput` uses an OpenAI-compatible endpoint. The local bridge calls Ollama native `/api/chat` and forces `think: false`.

Machine-local files:

- `~/.local/bin/ollama_vinput_bridge.py`
- `~/.config/systemd/user/ollama-vinput-bridge.service`

Provider endpoint:

```text
http://127.0.0.1:11435/v1
```

## Input-method environment

`~/.config/environment.d/fcitx5.conf`:

```ini
XMODIFIERS=@im=fcitx
QT_IM_MODULE=fcitx
```

This machine does not set `GTK_IM_MODULE`; GTK follows the GNOME/Wayland default path.

Key entries in `~/.config/fcitx5/conf/vinput.conf`:

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

## Useful commands

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
systemctl --user restart vinput-daemon.service
systemctl --user restart ollama-vinput-bridge.service
journalctl --user -u vinput-daemon.service -n 100 --no-pager
journalctl --user -u ollama-vinput-bridge.service -n 100 --no-pager
journalctl --user -u vinput-daemon.service -f --since now --no-pager
```

## Troubleshooting priority

1. ASR misrecognition: homophones, proper nouns, numbers, Chinese/English mixing.
2. Post-processing instability: prompt/model mismatch.
3. Daemon activation failure: check `libvosk.so`, wrapper, systemd override, and Ollama bridge first.
