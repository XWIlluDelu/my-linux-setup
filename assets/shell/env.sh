# Shared shell environment for bash + zsh, login and interactive.
# POSIX sh; idempotent, so sourcing it more than once is harmless.
#
# Machine-specific PATH entries (CUDA, MATLAB, language SDKs, etc.) are added
# locally below, not in the repo. See LOCAL_ENV_AGENT_NOTES.md.

_prepend_path() {
  case ":$PATH:" in
    *":$1:"*) ;;
    *) [ -d "$1" ] && PATH="$1:$PATH" ;;
  esac
}

# User-local binaries (starship, uv, etc.)
_prepend_path "$HOME/.local/bin"

export PATH
unset -f _prepend_path

# Keep conda/venv from rewriting the prompt; starship owns it.
export CONDA_CHANGEPS1=false
export VIRTUAL_ENV_DISABLE_PROMPT=1
