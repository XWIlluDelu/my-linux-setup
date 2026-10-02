# fcitx5-vinput

Workstation configuration notes for **fcitx5-vinput 2.4.0**, checked on 2026-10-03.

| Pipeline | Streaming ASR | Text cleanup and command mode |
|---|---|---|
| **Bailian — active default** | `qwen-audio-3.1-asr-flash-streaming` | `qwen3.7-flash`, thinking disabled |
| Gateway — manually selectable alternative | `gemini-3.5-transcribe-live` | `aistudio/gemini-flash-lite` |

`vinput-profile` switches ASR, cleanup, and command mode together. The gateway
is not automatic failover; Ollama is no longer part of the configured pipelines.
Custom adapters and the profile helper remain machine-local, not bundled here.
No credentials or runtime logs belong in this repository.

See the [setup and configuration guide](fcitx5-vinput-setup-EN.md) for endpoints,
private configuration fields, switching, input bindings, and verification.
