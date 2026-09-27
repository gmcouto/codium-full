#!/usr/bin/env bash
# Verification script for Phase 1: Foundation and Build Invariants
set -euo pipefail

echo "=== Phase 1 Invariant Verification ==="

# 1. Base & Supervision Invariants (BASE-01, BASE-02)
echo "[1/9] Checking base image & supervision invariants..."
if [ ! -x /init ]; then
    echo "ERROR: /init entrypoint does not exist or is not executable" >&2
    exit 1
fi

id abc >/dev/null 2>&1 || {
    echo "ERROR: Non-root user 'abc' not found" >&2
    exit 1
}

# Assert /config is not polluted with preinstalled binary toolchains
if [ -d /config ] && [ "$(find /config -mindepth 1 -maxdepth 1 | wc -l)" -gt 0 ]; then
    echo "WARNING: /config is not empty at build time"
fi

# 2. Node.js 22 LTS (RUN-01, D-03)
echo "[2/9] Checking Node.js 22 LTS toolchain..."
NODE_VER=$(node --version)
echo "Node.js version: ${NODE_VER}"
echo "${NODE_VER}" | grep -E '^v22\.' || {
    echo "ERROR: Node.js version is not 22.x LTS" >&2
    exit 1
}
NPM_VER=$(npm --version)
echo "npm version: ${NPM_VER}"

# 3. Python 3.12 (RUN-02, D-04)
echo "[3/9] Checking Python 3.12 stack & virtual environment creation..."
PY_VER=$(python3 --version)
echo "Python version: ${PY_VER}"
echo "${PY_VER}" | grep -E '3\.12\.' || {
    echo "ERROR: Python version is not 3.12" >&2
    exit 1
}

su -s /bin/bash abc -c 'python3 -m venv /tmp/test-venv && /tmp/test-venv/bin/python --version && rm -rf /tmp/test-venv' || {
    echo "ERROR: Python venv creation failed as user 'abc'" >&2
    exit 1
}

# 4. Rust Toolchain (RUN-02, D-05)
echo "[4/9] Checking Rust toolchain and user execution..."
su -s /bin/bash abc -c 'rustc --version && cargo --version' || {
    echo "ERROR: rustc or cargo execution failed as user 'abc'" >&2
    exit 1
}

# Check RUSTUP_HOME and CARGO_HOME invariants
if [ "${RUSTUP_HOME:-}" != "/opt/rust/rustup" ]; then
    echo "ERROR: RUSTUP_HOME is not set to /opt/rust/rustup (got: ${RUSTUP_HOME:-unset})" >&2
    exit 1
fi
if [ "${CARGO_HOME:-}" = "/opt/rust/cargo" ]; then
    echo "ERROR: CARGO_HOME must not be globally set to /opt/rust/cargo to prevent write permission issues for user 'abc'" >&2
    exit 1
fi

# 5. Go Toolchain (RUN-02, D-06)
echo "[5/9] Checking Go toolchain and user execution..."
if [ ! -x /usr/local/go/bin/go ]; then
    echo "ERROR: Go binary not found at /usr/local/go/bin/go" >&2
    exit 1
fi
su -s /bin/bash abc -c 'go version' || {
    echo "ERROR: go command execution failed as user 'abc'" >&2
    exit 1
}

# 6. Native C/GTK Libraries (RUN-03, D-04)
echo "[6/9] Checking native development libraries via pkg-config..."
REQUIRED_LIBS=(
    "openssl"
    "glib-2.0"
    "gdk-pixbuf-2.0"
    "pango"
    "atk"
    "gtk+-3.0"
    "javascriptcoregtk-4.1"
    "libsoup-3.0"
    "webkit2gtk-4.1"
)
for lib in "${REQUIRED_LIBS[@]}"; do
    pkg-config --exists "${lib}" || {
        echo "ERROR: pkg-config library '${lib}' missing" >&2
        exit 1
    }
    echo "  ✓ ${lib} ($(pkg-config --modversion "${lib}"))"
done

# 7. Docker Client Tooling (RUN-04, D-07)
echo "[7/9] Checking Docker client tooling (CLI, Compose, Buildx)..."
docker --version || {
    echo "ERROR: docker CLI not available" >&2
    exit 1
}
docker compose version || {
    echo "ERROR: docker compose CLI plugin not available" >&2
    exit 1
}
docker buildx version || {
    echo "ERROR: docker buildx CLI plugin not available" >&2
    exit 1
}

# 8. Developer Utilities (TOOL-03, D-08)
echo "[8/9] Checking developer utilities (gh, rg, fd, fzf, jq)..."
gh --version >/dev/null || { echo "ERROR: gh missing" >&2; exit 1; }
rg --version >/dev/null || { echo "ERROR: rg missing" >&2; exit 1; }
fd --version >/dev/null || { echo "ERROR: fd missing" >&2; exit 1; }
fzf --version >/dev/null || { echo "ERROR: fzf missing" >&2; exit 1; }
jq --version >/dev/null || { echo "ERROR: jq missing" >&2; exit 1; }
echo "  ✓ gh, rg, fd, fzf, jq are all installed and functional"

# 9. Legacy Multiplexer Exclusion (TOOL-04, D-09)
echo "[9/9] Checking strict absence of tmux and screen..."
if command -v tmux >/dev/null 2>&1; then
    echo "ERROR: tmux is present in container (violates TOOL-04 / D-09)" >&2
    exit 1
fi
if command -v screen >/dev/null 2>&1; then
    echo "ERROR: screen is present in container (violates TOOL-04 / D-09)" >&2
    exit 1
fi
echo "  ✓ tmux and screen are strictly absent"

echo "=== All Phase 1 Verification Checks PASSED Successfully ==="
exit 0
