# Local Env Agent Notes

This repo's `assets/` should only contain shell config for tools that `my-linux-setup` installs and manages.

Local machine-only tools should not be added to `assets/` by default.
Examples:
- `node` installed manually as latest
- ad-hoc SDK paths
- machine-specific proxy paths

When shell config has been overwritten and needs local recovery, use this workflow:

1. Detect whether a tool is actually installed before writing any shell config.
2. Only add config when the tool exists but the corresponding shell hook or PATH entry is missing.
3. Do not add config for tools that are not installed.

Priority checks:

- `direnv`
  - If `command -v direnv` succeeds and shell config does not contain `direnv hook`, add:
    - `eval "$(direnv hook zsh)"` to `~/.zshrc`
    - `eval "$(direnv hook bash)"` to `~/.bashrc`

- `uv`
  - If `command -v uv` succeeds, usually no extra config is needed if `~/.local/bin` is already in `PATH`.
  - Only add a PATH entry if `uv` exists in a local user bin directory that is not already covered.

- `node`
  - Do not add Node config to repo `assets/`.
  - If `command -v node` succeeds but the local installation path is not available in interactive shells, add the minimum PATH entry only to the current machine's shell files.
  - Do not assume a fixed Node install path unless it is already present on the machine.

- `miniforge`
  - Miniforge is installed by setup, but do not add it to repo `assets/` by default unless that becomes an explicit repo policy.
  - Prefer the official `conda init` shell block in the current machine's `~/.zshrc` and `~/.bashrc`.
  - Do not add Miniforge PATH entries to repo `assets/`.
  - Only fall back to a direct PATH entry when `conda init` is not viable.

Edit principle:

- Keep repo `assets/` generic and reproducible.
- Keep local machine recovery minimal and explicit.
- Prefer adding the smallest missing shell snippet instead of rewriting unrelated config.
