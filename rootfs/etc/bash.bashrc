[[ "$-" != *i* ]] && return
CANONICAL_PATH="/usr/local/go/bin:/opt/rust/cargo/bin:/config/.local/share/pnpm:/usr/local/bin:/usr/bin:/bin"
case ":${PATH:-}:" in
  *:"$CANONICAL_PATH":*) ;;
  *) export PATH="$CANONICAL_PATH${PATH:+:$PATH}" ;;
esac
if command -v zoxide >/dev/null 2>&1; then
  eval "$(zoxide init bash)"
fi
if [ -f /usr/share/doc/fzf/examples/key-bindings.bash ]; then
  . /usr/share/doc/fzf/examples/key-bindings.bash
fi
if [ -f /usr/share/doc/fzf/examples/completion.bash ]; then
  . /usr/share/doc/fzf/examples/completion.bash
elif [ -f /usr/share/bash-completion/completions/fzf ]; then
  . /usr/share/bash-completion/completions/fzf
fi
