# fcitx5-vinput Setup Notes

Recorded against the workstation's **fcitx5-vinput 2.4.0** configuration on
2026-10-03. Bailian remains the active pipeline; the gateway is an independently
selectable alternative, not automatic failover.

The custom ASR adapters and `vinput-profile` helper described below are
machine-local files, **not bundled in this repository or installed by the vinput
package**. These notes record their configuration, not a complete installer for
another machine. Credentials stay in `~/.config/vinput/config.json`, mode `0600`;
never commit that file or print its contents.

## Recorded pipelines

| Setting | Primary: `bailian` | Alternative: `gateway` |
|---|---|---|
| ASR provider ID | `provider.bailian.streaming` | `provider.gateway.streaming` |
| Streaming ASR model | `qwen-audio-3.1-asr-flash-streaming` | `gemini-3.5-transcribe-live` |
| Cleanup scene | `zh-en-polish-bailian` | `zh-en-polish-gateway` |
| LLM provider ID | `bailian` | `gateway` |
| Cleanup and command model | `qwen3.7-flash` | `aistudio/gemini-flash-lite` |
| LLM options | `enable_thinking: false` | Empty `extra_body` |
| LLM timeout | 10000 ms | 10000 ms |

The Flash-Lite alias currently maps to `gemini-flash-lite-latest`, not a pinned
upstream version. Recheck behavior if that mapping changes. Use the gateway's
CPA **client key**, not a management key or an upstream-provider key.

The old `qwen3-asr-flash-realtime` `/realtime` setup and `qwen-flash` cleanup
model have been replaced. Ollama providers, bridge services, warmup timers, and
`zh-en-polish-local` are not part of these configured pipelines. A built-in
`sherpa-onnx` provider entry does not establish a configured offline fallback.

## Install or upgrade the package

Check [upstream releases](https://github.com/xifan2333/fcitx5-vinput/releases)
for a package matching the distribution and architecture. The recorded version
is not a requirement to downgrade a newer installation.

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

For other Debian/Ubuntu releases, use a matching release asset rather than a
package built for a different distribution release. The custom Python adapters
also require `websockets` with `websockets.sync.client`; this workstation uses
`python3-websockets` 17.1. They do not need a vendor SDK, Ollama, or downloaded
local ASR models.

For a new installation:

```bash
vinput init
systemctl --user enable --now vinput-daemon.service
fcitx5 -r
```

Do not use `vinput init --force` over an existing private configuration. Package
installation alone does not register or restore the machine-local adapters.
Do not overwrite the custom Bailian adapter with the legacy registry provider.

## ASR adapters

| Provider | Machine-local script | WebSocket endpoint |
|---|---|---|
| Bailian | `~/.local/share/vinput/providers/bailian/streaming` | `wss://dashscope.aliyuncs.com/api-ws/v1/inference` |
| Gateway | `~/.local/share/vinput/providers/gateway/gemini-live` | `wss://www.ai.xwilludelu.cn/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent` |

Both entries in `asr.providers` use `type: "command"`, `command: "python3"`,
`args: ["/absolute/path/to/the/script"]`, and `timeout_ms: 60000`. Use the actual
absolute script path: command arguments do not expand shell `~` expressions.
The provider ID must end in **`.streaming`** because vinput 2.4 selects the JSONL
backend by that suffix, not by the executable's filename.

### Provider environment

Set these fields under the matching provider's `env` object in the private
configuration. Placeholders below are not usable credentials.

**Bailian:**

```json
{
  "VINPUT_ASR_API_KEY": "<bailian-key>",
  "VINPUT_ASR_MODEL": "qwen-audio-3.1-asr-flash-streaming",
  "VINPUT_ASR_URL": "wss://dashscope.aliyuncs.com/api-ws/v1/inference",
  "VINPUT_ASR_LANGUAGE": "zh,en",
  "VINPUT_ASR_TIMEOUT": "30",
  "VINPUT_ASR_FINISH_GRACE_SECS": "8.0"
}
```

**Gateway:**

```json
{
  "VINPUT_ASR_API_KEY": "<cpa-client-key>",
  "VINPUT_ASR_MODEL": "gemini-3.5-transcribe-live",
  "VINPUT_ASR_URL": "wss://www.ai.xwilludelu.cn/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent",
  "VINPUT_ASR_TIMEOUT": "15",
  "VINPUT_ASR_FINISH_GRACE_SECS": "8.0"
}
```

Both adapters accept vinput JSONL with Base64 PCM16, 16 kHz, mono audio. They
emit one complete final per nonempty successful recording, not a final for each
sentence. The eight-second finish budget stays below vinput 2.4's ten-second
wait. Errors, cancellation, or timeout must not promote partial text to success.

- **Bailian:** uses binary audio and `run-task` / `finish-task`, aggregates by
  sentence ID across pauses, and waits for `task-finished` before its final.
- **Gemini:** uses the native Live transcription protocol, not uploaded-file
  transcription SSE. Automatic language detection and manual activity boundaries
  preserve the whole recording. The adapter replaces partial hypotheses and
  waits for authoritative transcription plus post-finish `generationComplete`;
  conversational `modelTurn` text is not dictation. It drains stdin while the
  network connects so startup cannot block capture or lose the audio prefix.

Neither adapter persists recordings, transcripts, credentials, or usage logs.

## LLM providers and scenes

The `llm.providers` entries are:

```json
[
  {
    "id": "bailian",
    "base_url": "https://dashscope.aliyuncs.com/compatible-mode/v1",
    "api_key": "<bailian-key>",
    "extra_body": {"enable_thinking": false}
  },
  {
    "id": "gateway",
    "base_url": "https://www.ai.xwilludelu.cn/v1",
    "api_key": "<cpa-client-key>",
    "extra_body": {}
  }
]
```

Each key appears in the corresponding ASR environment and LLM provider entry.
The gateway administrator page at `media.ai.xwilludelu.cn` is **not** an API base
URL. Do not copy Bailian's `enable_thinking` setting into the gateway provider;
Flash-Lite worked with defaults, while `reasoning_effort: "none"` was rejected.

| Scene | Purpose | Provider / model |
|---|---|---|
| `zh-en-polish-bailian` | Default bilingual cleanup | `bailian` / `qwen3.7-flash` |
| `zh-en-polish-gateway` | Alternative bilingual cleanup | `gateway` / `aistudio/gemini-flash-lite` |
| `__raw__` | ASR only, without cleanup | None |
| `__command__` | Apply a spoken edit to selected text | Paired with the selected profile |

The cleanup scenes share the existing bilingual prompt: preserve meaning and
technical terms, remove fillers and unwanted repetition, format lists and
paragraphs, and treat dictated instructions as content. Command mode instead
interpolates `{{selected}}` and `{{asr}}` into its editing prompt. It currently
has no keyboard shortcut.

vinput 2.4 sends cleanup as a **nonstreaming** completion and expects
`{"candidates":["..."]}` JSON. Its request uses `stream=false`, `temperature=0.2`,
and `response_format={"type":"json_object"}`. Provider `extra_body` cannot
replace the protected stream, messages, or response-format fields. Measure the
full cleanup response, not API first-token latency.

## Select a complete pipeline

The machine-local helper is `~/.local/bin/vinput-profile`:

```bash
vinput-profile status
vinput-profile --dry-run gateway  # Inspect the proposed selection only
vinput-profile gateway            # Apply the alternative pipeline
vinput-profile bailian            # Restore the primary pipeline
```

The profile-name invocation is an explicit mutation: it changes the active ASR,
cleanup scene, and `__command__` provider/model together. It preserves secrets,
prompts, timeouts, and unrelated settings, writes atomically with mode `0600`,
and restarts a running idle daemon. A busy daemon causes refusal; restart
failure restores the previous configuration and attempts daemon recovery. A
stopped daemon stays stopped. Selecting the current profile makes no change.

Separate `vinput provider use` and `vinput scene use` calls do not pair command
mode. The helper reports mismatched combinations as `mixed/custom`. `__raw__`
is available for ASR-only use, but is not a third complete pipeline.

## Input-method and audio settings

`~/.config/environment.d/fcitx5.conf`:

```ini
XMODIFIERS=@im=fcitx
QT_IM_MODULE=fcitx
```

GTK follows the GNOME/Wayland default path; this setup does not set
`GTK_IM_MODULE`.

The current `~/.config/fcitx5/conf/vinput.conf` keeps the 2.4 defaults
(`TriggerMode=Both`, `TriggerKey=Alt_R`, `MenuKey=Shift_R`) and clears command and
page-navigation bindings. An explicit equivalent is:

```ini
TriggerMode=Both
CommandKeys=
PagePrevKeys=
PageNextKeys=

[TriggerKey]
0=Alt_R

[MenuKey]
0=Shift_R
```

The old separate `SceneMenuKey=F8` / `AsrMenuKey` example is not the current
configuration. Hold `Alt_R` to record and release to finish.

Capture uses the default device, normalization is enabled, and input gain is
`1.0`. Local VAD is enabled with threshold `0.45`, minimum speech `0.15` seconds,
minimum silence `0.5` seconds, and padding `300` ms. Output ducking remains
**disabled**; WirePlumber is needed only if enabling that optional feature.
These local settings are separate from each upstream ASR protocol's VAD.

## Verification and safe inspection

```bash
vinput --version
vinput-profile status
vinput-profile --dry-run gateway
vinput daemon status
systemctl --user status vinput-daemon.service

# Offline tests, available with the machine-local adapters and helper:
python3 -B -m unittest discover \
  -s ~/.local/share/vinput/providers/bailian/tests -v
python3 -B -m unittest discover \
  -s ~/.local/share/vinput/providers/gateway/tests -v
```

Avoid printing the full configuration or provider listings, including
`vinput -j provider list`: they can expose keys. Do not enable `VINPUT_DEBUG`
when capturing or sharing daemon logs; vinput 2.4 debug output can include
Authorization headers. `vinput llm test <provider>` is a live API call, not an
offline check.

Workstation acceptance on 2026-10-02 exercised both streaming adapters and
vinput's complete JSON-candidates cleanup contract. An isolated native-daemon
check also covered Gemini audio arriving before network readiness, speech
separated by pauses, one processed result, and return to idle. Fcitx desktop
key handling and display were not visually tested in that check.

**Keep Bailian as primary.** The gateway's complete cleanup latency was
comparable in the small samples, but its first ASR partial was slower and startup
varied. It is a usable non-Qwen alternative, not an established speed upgrade.
Detailed local evidence and adapter maintenance notes remain in
`~/.local/share/vinput/providers/{bailian,gateway}/README.md`; measurements and
private runtime configuration are not copied into this repository.
