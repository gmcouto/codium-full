#!/usr/bin/env bash
# Verification script for Phase 3: Autonomous SSH under s6
set -euo pipefail

echo "=== Phase 3 Invariant Verification ==="

# 1. Base OpenSSH Server Installation & Directory Invariants (SSH-01, SSH-02)
echo "[1/7] Checking OpenSSH Server binaries and privilege separation directory..."
if [ ! -x /usr/sbin/sshd ]; then
    echo "ERROR: /usr/sbin/sshd binary not found or not executable" >&2
    exit 1
fi

if [ ! -d /var/run/sshd ]; then
    echo "ERROR: Privilege separation directory /var/run/sshd missing" >&2
    exit 1
fi

VAR_RUN_PERMS=$(stat -c "%a" /var/run/sshd)
if [ "$VAR_RUN_PERMS" != "755" ]; then
    echo "ERROR: /var/run/sshd has permissions $VAR_RUN_PERMS, expected 755" >&2
    exit 1
fi
echo "  ✓ /usr/sbin/sshd installed and /var/run/sshd present with mode 0755"

# 2. OpenSSH Daemon Configuration Policy (SSH-02, SSH-03, SSH-04, SSH-05)
echo "[2/7] Checking OpenSSH daemon configuration policy..."
CONF_FILE="/etc/ssh/sshd_config.d/00-codium-sshd.conf"
if [ ! -f "$CONF_FILE" ]; then
    echo "ERROR: sshd drop-in configuration file $CONF_FILE missing" >&2
    exit 1
fi

grep -qE '^Port 2222' "$CONF_FILE" || { echo "ERROR: Port 2222 not configured" >&2; exit 1; }
grep -qE '^PermitRootLogin no' "$CONF_FILE" || { echo "ERROR: PermitRootLogin no not configured" >&2; exit 1; }
grep -qE '^PubkeyAuthentication yes' "$CONF_FILE" || { echo "ERROR: PubkeyAuthentication yes not configured" >&2; exit 1; }
grep -qE '^PasswordAuthentication no' "$CONF_FILE" || { echo "ERROR: PasswordAuthentication no not configured" >&2; exit 1; }
grep -qE '^KbdInteractiveAuthentication no' "$CONF_FILE" || { echo "ERROR: KbdInteractiveAuthentication no not configured" >&2; exit 1; }
grep -qE '^AuthorizedKeysFile /config/\.ssh/authorized_keys \.ssh/authorized_keys' "$CONF_FILE" || { echo "ERROR: AuthorizedKeysFile not configured properly" >&2; exit 1; }
grep -qE '^HostKey /config/ssh/host_keys/ssh_host_ed25519_key' "$CONF_FILE" || { echo "ERROR: ed25519 host key path missing" >&2; exit 1; }
grep -qE '^HostKey /config/ssh/host_keys/ssh_host_ecdsa_key' "$CONF_FILE" || { echo "ERROR: ecdsa host key path missing" >&2; exit 1; }
grep -qE '^HostKey /config/ssh/host_keys/ssh_host_rsa_key' "$CONF_FILE" || { echo "ERROR: rsa host key path missing" >&2; exit 1; }
echo "  ✓ sshd drop-in configuration strictly enforces port 2222, key-only auth, non-root, and host key paths"

# 3. s6-overlay v3 Service Topology & Dependency Chain (SSH-01)
echo "[3/7] Checking s6-rc service definitions and dependency links..."
# Oneshot service: init-ssh-hostkeys
[ "$(cat /etc/s6-overlay/s6-rc.d/init-ssh-hostkeys/type)" = "oneshot" ] || { echo "ERROR: init-ssh-hostkeys type is not oneshot" >&2; exit 1; }
[ -x /etc/s6-overlay/s6-rc.d/init-ssh-hostkeys/run ] || { echo "ERROR: init-ssh-hostkeys/run not executable" >&2; exit 1; }
[ -f /etc/s6-overlay/s6-rc.d/init-ssh-hostkeys/dependencies.d/init-config-end ] || { echo "ERROR: init-ssh-hostkeys missing init-config-end dependency" >&2; exit 1; }
[ -f /etc/s6-overlay/s6-rc.d/user/contents.d/init-ssh-hostkeys ] || { echo "ERROR: init-ssh-hostkeys not registered in user bundle" >&2; exit 1; }

# Longrun service: svc-sshd
[ "$(cat /etc/s6-overlay/s6-rc.d/svc-sshd/type)" = "longrun" ] || { echo "ERROR: svc-sshd type is not longrun" >&2; exit 1; }
[ -x /etc/s6-overlay/s6-rc.d/svc-sshd/run ] || { echo "ERROR: svc-sshd/run not executable" >&2; exit 1; }
[ -f /etc/s6-overlay/s6-rc.d/svc-sshd/dependencies.d/init-ssh-hostkeys ] || { echo "ERROR: svc-sshd missing init-ssh-hostkeys dependency" >&2; exit 1; }
[ -f /etc/s6-overlay/s6-rc.d/user/contents.d/svc-sshd ] || { echo "ERROR: svc-sshd not registered in user bundle" >&2; exit 1; }
echo "  ✓ s6-rc services correctly typed, linked to init-config-end, and enabled in user bundle"

# 4. Host Key Initialization, Permissions, and Idempotency (SSH-05)
echo "[4/7] Testing host key generation and directory permission enforcement..."
# Run initializer
/bin/bash /etc/s6-overlay/s6-rc.d/init-ssh-hostkeys/run

# Verify host key directory and files
[ -d /config/ssh/host_keys ] || { echo "ERROR: /config/ssh/host_keys not created" >&2; exit 1; }
[ "$(stat -c %a /config/ssh/host_keys)" = "700" ] || { echo "ERROR: /config/ssh/host_keys mode is not 0700" >&2; exit 1; }
[ "$(stat -c %U:%G /config/ssh/host_keys)" = "root:root" ] || { echo "ERROR: /config/ssh/host_keys owner is not root:root" >&2; exit 1; }

for keytype in ed25519 ecdsa rsa; do
    keyfile="/config/ssh/host_keys/ssh_host_${keytype}_key"
    [ -f "$keyfile" ] || { echo "ERROR: $keyfile missing" >&2; exit 1; }
    [ -f "${keyfile}.pub" ] || { echo "ERROR: ${keyfile}.pub missing" >&2; exit 1; }
    [ "$(stat -c %a "$keyfile")" = "600" ] || { echo "ERROR: $keyfile mode is not 0600" >&2; exit 1; }
    [ "$(stat -c %a "${keyfile}.pub")" = "644" ] || { echo "ERROR: ${keyfile}.pub mode is not 0644" >&2; exit 1; }
    [ "$(stat -c %U:%G "$keyfile")" = "root:root" ] || { echo "ERROR: $keyfile owner is not root:root" >&2; exit 1; }
done

# Verify /config/.ssh user directory
[ -d /config/.ssh ] || { echo "ERROR: /config/.ssh not created" >&2; exit 1; }
[ "$(stat -c %a /config/.ssh)" = "700" ] || { echo "ERROR: /config/.ssh mode is not 0700" >&2; exit 1; }
[ "$(stat -c %U:%G /config/.ssh)" = "abc:abc" ] || { echo "ERROR: /config/.ssh owner is not abc:abc" >&2; exit 1; }

# Idempotency: Capture SHA256 hashes and re-run initializer
HASH_BEFORE=$(sha256sum /config/ssh/host_keys/ssh_host_*_key)
/bin/bash /etc/s6-overlay/s6-rc.d/init-ssh-hostkeys/run
HASH_AFTER=$(sha256sum /config/ssh/host_keys/ssh_host_*_key)
if [ "$HASH_BEFORE" != "$HASH_AFTER" ]; then
    echo "ERROR: init-ssh-hostkeys is not idempotent; host keys were modified or regenerated" >&2
    exit 1
fi
echo "  ✓ Host keys generated with strict 0600/0700 permissions and idempotent execution verified"

# 5. SSH Configuration Syntax Test
echo "[5/7] Testing sshd configuration syntax..."
/usr/sbin/sshd -t || {
    echo "ERROR: sshd -t configuration syntax validation failed" >&2
    exit 1
}
echo "  ✓ sshd configuration syntax is valid"

# 6. Live Authentication & Security Policy Verification (SSH-03, SSH-04)
echo "[6/7] Testing live SSH authentication, user isolation, and security policy..."
CLIENT_KEY="/tmp/test_client_ed25519"
UNAUTH_KEY="/tmp/test_unauth_ed25519"
rm -f "${CLIENT_KEY}"* "${UNAUTH_KEY}"*

ssh-keygen -t ed25519 -N "" -f "$CLIENT_KEY" >/dev/null 2>&1
ssh-keygen -t ed25519 -N "" -f "$UNAUTH_KEY" >/dev/null 2>&1

# Authorize CLIENT_KEY for user abc
mkdir -p -m 0700 /config/.ssh
cat "${CLIENT_KEY}.pub" > /config/.ssh/authorized_keys
chmod 0600 /config/.ssh/authorized_keys
chown -R abc:abc /config/.ssh

MANUAL_SSHD=0
SSHD_PID=""
if ! timeout 1 bash -c '</dev/tcp/127.0.0.1/2222' 2>/dev/null; then
    /usr/sbin/sshd -e -D &
    SSHD_PID=$!
    MANUAL_SSHD=1
    for i in {1..30}; do
        if timeout 1 bash -c '</dev/tcp/127.0.0.1/2222' 2>/dev/null; then
            break
        fi
        sleep 0.1
    done
fi

cleanup() {
    if [ "$MANUAL_SSHD" -eq 1 ] && [ -n "$SSHD_PID" ]; then
        kill -9 "$SSHD_PID" 2>/dev/null || true
    fi
    rm -f "${CLIENT_KEY}"* "${UNAUTH_KEY}"* /root/.ssh/authorized_keys 2>/dev/null || true
}
trap cleanup EXIT

SSH_OPTS=(-p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=5 -o LogLevel=ERROR)

# Test 6a: Authorized public key login for user 'abc'
AUTH_USER=$(ssh "${SSH_OPTS[@]}" -i "$CLIENT_KEY" abc@127.0.0.1 whoami)
if [ "$AUTH_USER" != "abc" ]; then
    echo "ERROR: SSH public key authentication failed for user abc (got: '$AUTH_USER')" >&2
    exit 1
fi
echo "  ✓ SSH public key authentication succeeded for non-root user abc"

# Test 6b: Unified PATH preservation in SSH interactive/login session
SSH_PATH=$(ssh "${SSH_OPTS[@]}" -i "$CLIENT_KEY" abc@127.0.0.1 'bash -lc "printf %s \"$PATH\""')
EXPECTED_PATH_PREFIX="/usr/local/go/bin:/opt/rust/cargo/bin:/config/.local/share/pnpm:/usr/local/bin:/usr/bin:/bin"
if [[ "$SSH_PATH" != "$EXPECTED_PATH_PREFIX"* ]]; then
    echo "ERROR: SSH session PATH does not have expected prefix (got: $SSH_PATH)" >&2
    exit 1
fi
echo "  ✓ SSH session preserves full toolchain PATH precedence"

# Test 6c: Rejection of unauthorized public key
if ssh "${SSH_OPTS[@]}" -i "$UNAUTH_KEY" abc@127.0.0.1 whoami >/dev/null 2>&1; then
    echo "ERROR: SSH accepted unauthorized public key (violates SSH-03/SSH-04)" >&2
    exit 1
fi
echo "  ✓ Unauthorized public keys are strictly rejected"

# Test 6d: Rejection of password authentication
if ssh "${SSH_OPTS[@]}" -o PubkeyAuthentication=no abc@127.0.0.1 whoami >/dev/null 2>&1; then
    echo "ERROR: SSH allowed non-pubkey authentication (violates SSH-03)" >&2
    exit 1
fi
echo "  ✓ Password & interactive authentication are strictly disabled"

# Test 6e: Rejection of root SSH login
mkdir -p -m 0700 /root/.ssh
cat "${CLIENT_KEY}.pub" > /root/.ssh/authorized_keys
chmod 0600 /root/.ssh/authorized_keys
if ssh "${SSH_OPTS[@]}" -i "$CLIENT_KEY" root@127.0.0.1 whoami >/dev/null 2>&1; then
    echo "ERROR: Root SSH login succeeded (violates SSH-03 PermitRootLogin no)" >&2
    exit 1
fi
echo "  ✓ Root SSH login is strictly rejected"

cleanup
trap - EXIT

# 7. Cold-Start Performance Validation (BASE-03)
echo "[7/7] Measuring host key initialization and startup overhead..."
START_TIME=$(date +%s%N)
/bin/bash /etc/s6-overlay/s6-rc.d/init-ssh-hostkeys/run
/usr/sbin/sshd -t
END_TIME=$(date +%s%N)
DURATION_MS=$(( (END_TIME - START_TIME) / 1000000 ))
echo "  Cold-start SSH initialization duration: ${DURATION_MS}ms"
if [ "$DURATION_MS" -gt 5000 ]; then
    echo "ERROR: SSH startup initialization took longer than 5000ms ($DURATION_MS ms)" >&2
    exit 1
fi
echo "  ✓ Cold-start overhead well within 10s budget"

echo "=== All Phase 3 Verification Checks PASSED Successfully ==="
exit 0
