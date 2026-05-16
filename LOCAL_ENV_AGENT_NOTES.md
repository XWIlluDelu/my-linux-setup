# Local environment notes

Repository rule: `assets/` contains only generic configuration that `my-linux-setup` installs and manages. Do not add machine-specific PATH entries, proxy settings, SDK paths, or manually installed tool hooks to repository assets.

## Managed shell files

`shell sync` and `install-shell-environment.sh --config-only` overwrite:

- `~/.profile`
- `~/.bashrc`
- `~/.zshrc`
- `~/.config/starship.toml`

They do not own arbitrary local shell snippets outside those files.

## Local recovery policy

When a local shell feature disappears after a managed sync:

1. Check that the tool is installed on this machine.
2. Add only the minimum missing hook or PATH entry.
3. Keep the change local to the machine; do not copy it into `assets/` unless it becomes a repo policy.

Common local-only cases:

| Tool | Policy |
|---|---|
| `direnv` | If installed and the hook is absent, add `eval "$(direnv hook zsh)"` to `~/.zshrc` or `eval "$(direnv hook bash)"` to `~/.bashrc`. |
| `uv` | Usually needs no shell config when `~/.local/bin` is already in `PATH`; add a PATH entry only if the installed binary is otherwise unreachable. |
| manually installed Node.js | Do not add Node.js paths to repo assets. Add the smallest local PATH entry only when `node` exists but interactive shells cannot find it. |
| Miniforge | Setup installs Miniforge as a user prefix, but repo assets do not initialize conda. Prefer `conda init` in local shell files; use direct PATH only when `conda init` is not viable. |

Keep local recovery explicit and minimal.
