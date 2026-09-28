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

# This must run against the uninitialized image with no /config mount and with
# the image entrypoint overridden. Runtime persistence is a separate test.
if find /config -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
    echo "ERROR: image contains build-time files under /config" >&2
    find /config -mindepth 1 -maxdepth 1 -print >&2
    exit 1
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
case "${CARGO_HOME-}" in
    ""|/config/.cargo) ;;
    *)
        echo "ERROR: CARGO_HOME must be unset or /config/.cargo (got: ${CARGO_HOME})" >&2
        exit 1
        ;;
esac

# 5. Go Toolchain (RUN-02, D-06)
echo "[5/9] Checking Go toolchain and user execution..."
if [ ! -x /usr/local/go/bin/go ]; then
    echo "ERROR: Go binary not found at /usr/local/go/bin/go" >&2
    exit 1
fi
if [ "$(readlink -f "$(command -v go)")" != /usr/local/go/bin/go ]; then
    echo "ERROR: go does not resolve to /usr/local/go/bin/go (got: $(command -v go))" >&2
    exit 1
fi
su -s /bin/bash abc -c 'test "$(readlink -f "$(command -v go)")" = /usr/local/go/bin/go && go version | grep -F " go1.24.1 "' || {
    echo "ERROR: expected Go 1.24.1 system binary is not executable as user 'abc'" >&2
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
# Phase 1 verifies installation only. The test harness intentionally does not
# mount a Docker socket, so daemon authorization is outside this test's scope.
echo "[7/9] Checking Docker client tooling as user 'abc' (daemon access not tested)..."
su -s /bin/bash abc -c 'docker --version' || {
    echo "ERROR: docker CLI not available to user 'abc'" >&2
    exit 1
}
su -s /bin/bash abc -c 'docker compose version' || {
    echo "ERROR: docker compose CLI plugin not available to user 'abc'" >&2
    exit 1
}
su -s /bin/bash abc -c 'docker buildx version' || {
    echo "ERROR: docker buildx CLI plugin not available to user 'abc'" >&2
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
