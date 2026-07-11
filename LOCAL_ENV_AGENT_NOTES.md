# Local environment notes

Repository rule: `assets/` contains only generic configuration that `my-linux-setup` installs and manages. Do not add machine-specific PATH entries, proxy settings, SDK paths, or manually installed tool hooks to repository assets.

## Managed shell files

`shell sync` and `install-shell-environment.sh --config-only` overwrite:

- `~/.profile`
- `~/.bashrc`
- `~/.zshrc`
- `~/.config/shell/env.sh`
- `~/.config/shell/aliases.sh`
- `~/.config/starship.toml`
- `~/.local/state/linux-setup/shell-env-profile`
- `~/.local/state/linux-setup/shell-env.env`

A sync removes `~/.tmux.conf` only when its first line is the legacy marker `# Linux Setup tmux config`. It does not own arbitrary local shell snippets outside the listed files.

## Local recovery policy

When a local shell feature disappears after a managed sync:

1. Check that the tool is installed on this machine.
2. Add only the minimum missing hook or PATH entry.
3. Keep the change local to the machine; do not copy it into `assets/` unless it becomes a repo policy.

Common cases:

| Tool | Policy |
|---|---|
| `direnv` | Setup installs it when the package is available, and both managed interactive shell files include its hook. No local hook is normally needed. |
| `uv` | Usually needs no shell config when `~/.local/bin` is already in `PATH`; add a PATH entry only if the installed binary is otherwise unreachable. |
| manually installed Node.js | Do not add Node.js paths to repo assets. Add the smallest local PATH entry only when `node` exists but interactive shells cannot find it. |
| Miniforge | When selected, setup installs Miniforge as a user prefix, but repo assets do not initialize conda. Prefer `conda init` in local shell files; use direct PATH only when `conda init` is not viable. |

Keep local recovery explicit and minimal.
