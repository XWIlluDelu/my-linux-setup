# Shared interactive aliases for bash + zsh.

# ls -> eza, with coreutils fallback.
if command -v eza >/dev/null 2>&1; then
  alias ls='eza --icons --git --group-directories-first'
  alias ll='eza -al --icons --git --group-directories-first'
  alias la='eza -A --icons --git --group-directories-first'
  alias lt='eza --tree --level=2 --icons --git'
else
  alias ls='ls --color=auto'
  alias ll='ls -alFh --color=auto'
  alias la='ls -A --color=auto'
fi

# cat -> bat (auto-passthrough on a pipe). Debian ships it as batcat.
if command -v batcat >/dev/null 2>&1; then
  alias cat='batcat --paging=never'
elif command -v bat >/dev/null 2>&1; then
  alias cat='bat --paging=never'
fi

# fd: Debian ships the binary as fdfind; alias restores the standard name.
if ! command -v fd >/dev/null 2>&1 && command -v fdfind >/dev/null 2>&1; then
  alias fd='fdfind'
fi

# rm -> trash-put. trash-cli accepts -r/-f/-i for GNU rm compatibility, so
# `rm -rf` behaves; without it, real rm stays in place.
if command -v trash-put >/dev/null 2>&1; then
  alias rm='trash-put'
  alias tl='trash-list'
  alias trestore='trash-restore'
  alias tempty='trash-empty'
fi

alias grep='grep --color=auto'

alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'

alias df='df -h'
alias du='du -h'
alias free='free -h'
alias ip='ip -c=auto'

alias gs='git status'
alias ga='git add'
alias gc='git commit'
alias gp='git push'
alias gl='git log --oneline --graph --decorate -20'
alias gd='git diff'
