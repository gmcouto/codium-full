#!/bin/sh
export PNPM_HOME="/config/.local/share/pnpm"
export GOROOT="/usr/local/go"
export GOPATH="/config/go"
export RUSTUP_HOME="/opt/rust/rustup"
CANONICAL_PATH="/usr/local/go/bin:/opt/rust/cargo/bin:/config/.local/share/pnpm:/usr/local/bin:/usr/bin:/bin"
case ":${PATH:-}:" in
  *:"$CANONICAL_PATH":*) ;;
  *) export PATH="$CANONICAL_PATH${PATH:+:$PATH}" ;;
esac
