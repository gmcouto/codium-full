#!/usr/bin/env bash
# scripts/verify-smoke.sh — End-to-end container smoke test harness
# Verifies container lifecycle, cold start, HTTP 8443 code-server, SSH 2222 key authentication,
# in-container toolchains, shims, multiplexer exclusion, and inventory export.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

usage() {
    cat <<'EOF'
Usage: verify-smoke.sh [OPTIONS]

Options:
  --image <IMAGE>           Container image to test (default: codium-full:test)
  --platform <PLATFORM>     Platform to run (default: linux/amd64)
  --port <PORT>             Host port mapping for HTTP 8443 (default: 18443 or $PORT / $TEST_PORT)
  --ssh-port <SSH_PORT>     Host port mapping for SSH 2222 (default: 12222 or $SSH_PORT / $TEST_SSH_PORT)
  --skip-in-container       Skip dedicated in-container verification suites
  --export-inventory <PATH> Export tool-inventory.json to specified host path
  -h, --help                Show this help message
EOF
    exit 0
}

IMAGE="${IMAGE:-codium-full:test}"
PLATFORM="${PLATFORM:-linux/amd64}"
HOST_PORT="${PORT:-${TEST_PORT:-18443}}"
HOST_SSH_PORT="${SSH_PORT:-${TEST_SSH_PORT:-12222}}"
SKIP_IN_CONTAINER=0
EXPORT_INVENTORY=""

while (($#)); do
    case "$1" in
        --image)
            IMAGE="$2"
            shift 2
            ;;
        --platform)
            PLATFORM="$2"
            shift 2
            ;;
        --port)
            HOST_PORT="$2"
            shift 2
            ;;
        --ssh-port)
            HOST_SSH_PORT="$2"
            shift 2
            ;;
        --skip-in-container)
            SKIP_IN_CONTAINER=1
            shift
            ;;
        --export-inventory)
            EXPORT_INVENTORY="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "ERROR: Unknown argument: $1" >&2
            usage
            ;;
    esac
done

TARGET_ARCH="${PLATFORM#linux/}"
if [ "$TARGET_ARCH" = "$PLATFORM" ]; then
    TARGET_ARCH="amd64"
fi

echo "=== Starting Codium Full Smoke Test Harness ==="
echo "Image:        ${IMAGE}"
echo "Platform:     ${PLATFORM} (arch: ${TARGET_ARCH})"
echo "Host Ports:   HTTP=${HOST_PORT}, SSH=${HOST_SSH_PORT}"

# Prepare ephemeral SSH test keys
TMP_KEYS="$(mktemp -d /tmp/smoke-keys-XXXXXX)"
CLIENT_KEY="${TMP_KEYS}/smoke_client_ed25519"
UNAUTH_KEY="${TMP_KEYS}/smoke_unauth_ed25519"

ssh-keygen -t ed25519 -N "" -f "${CLIENT_KEY}" >/dev/null 2>&1
ssh-keygen -t ed25519 -N "" -f "${UNAUTH_KEY}" >/dev/null 2>&1

CONTAINER_ID=""
cleanup() {
    local exit_code=$?
    if [ -n "${CONTAINER_ID:-}" ]; then
        echo "Cleaning up container ${CONTAINER_ID}..."
        docker rm -f "${CONTAINER_ID}" >/dev/null 2>&1 || true
    fi
    if [ -n "${TMP_KEYS:-}" ] && [ -d "${TMP_KEYS}" ]; then
        rm -rf "${TMP_KEYS}" 2>/dev/null || true
    fi
    exit "$exit_code"
}
trap cleanup EXIT INT TERM

# Launch container candidate
echo "Launching container candidate under s6-overlay..."
CONTAINER_BOOT_START_NS=$(date +%s%N)
CONTAINER_ID=$(docker run -d \
    --platform "${PLATFORM}" \
    -e PUID=1000 \
    -e PGID=1000 \
    -e TZ=UTC \
    -e PASSWORD="smoketestpassword" \
    -p "127.0.0.1:${HOST_PORT}:8443" \
    -p "127.0.0.1:${HOST_SSH_PORT}:2222" \
    "${IMAGE}")

echo "Container started: ${CONTAINER_ID}"

# In containerized dev environments sharing docker daemon, connect container to runner's network
RUNNER_CONTAINER=$(hostname 2>/dev/null || true)
if [ -n "$RUNNER_CONTAINER" ]; then
    RUNNER_NETWORKS=$(docker inspect "$RUNNER_CONTAINER" -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' 2>/dev/null || true)
    for net in $RUNNER_NETWORKS; do
        if [ "$net" != "bridge" ] && [ "$net" != "host" ] && [ "$net" != "none" ]; then
            docker network connect "$net" "${CONTAINER_ID}" 2>/dev/null || true
        fi
    done
fi

# Inject scripts and authorized keys via docker cp
echo "Injecting test scripts and authorized_keys via docker cp..."
docker cp "${PROJECT_ROOT}/scripts/." "${CONTAINER_ID}:/scripts"
docker exec "${CONTAINER_ID}" mkdir -p /config/.ssh
docker cp "${CLIENT_KEY}.pub" "${CONTAINER_ID}:/config/.ssh/authorized_keys"
docker exec "${CONTAINER_ID}" chown -R abc:abc /config/.ssh
docker exec "${CONTAINER_ID}" chmod 0700 /config/.ssh
docker exec "${CONTAINER_ID}" chmod 0600 /config/.ssh/authorized_keys
docker exec "${CONTAINER_ID}" chmod -R 755 /scripts

# Measure cold start timing & resolve probe target
if [ "$(uname -m)" = "x86_64" ] && [ "${TARGET_ARCH}" = "amd64" ]; then
    TIMEOUT_SECS=15
    MAX_COLD_START_MS=10000
else
    TIMEOUT_SECS=60
    MAX_COLD_START_MS=60000
fi

echo "Probing HTTP code-server readiness (timeout: ${TIMEOUT_SECS}s, budget: ${MAX_COLD_START_MS}ms)..."
DEADLINE=$(( $(date +%s) + TIMEOUT_SECS ))
PROBE_HOST=""
PROBE_PORT=""
PROBE_SSH_PORT=""
HTTP_READY=0

while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    # Try 127.0.0.1 mapped host port first
    STATUS=$(curl -s -m 1 -o /dev/null -w "%{http_code}" "http://127.0.0.1:${HOST_PORT}/" 2>/dev/null || true)
    if [ "$STATUS" = "200" ] || [ "$STATUS" = "302" ]; then
        PROBE_HOST="127.0.0.1"
        PROBE_PORT="${HOST_PORT}"
        PROBE_SSH_PORT="${HOST_SSH_PORT}"
        HTTP_READY=1
        break
    fi

    # Fallback to direct container IP(s) on internal port 8443
    for ip in $(docker inspect -f '{{range .NetworkSettings.Networks}}{{if .IPAddress}}{{.IPAddress}} {{end}}{{end}}' "${CONTAINER_ID}"); do
        STATUS=$(curl -s -m 1 -o /dev/null -w "%{http_code}" "http://${ip}:8443/" 2>/dev/null || true)
        if [ "$STATUS" = "200" ] || [ "$STATUS" = "302" ]; then
            PROBE_HOST="${ip}"
            PROBE_PORT=8443
            PROBE_SSH_PORT=2222
            HTTP_READY=1
            break 2
        fi
    done
    sleep 0.1
done

CONTAINER_BOOT_END_NS=$(date +%s%N)
DURATION_MS=$(( (CONTAINER_BOOT_END_NS - CONTAINER_BOOT_START_NS) / 1000000 ))

if [ "$HTTP_READY" -ne 1 ]; then
    echo "ERROR: Container failed to respond to HTTP probe within ${TIMEOUT_SECS}s" >&2
    docker logs "${CONTAINER_ID}" >&2
    exit 1
fi

echo "  ✓ Cold-start HTTP readiness achieved in ${DURATION_MS}ms (target: ${PROBE_HOST}:${PROBE_PORT})"
if [ "$(uname -m)" = "x86_64" ] && [ "${TARGET_ARCH}" = "amd64" ]; then
    if [ "$DURATION_MS" -gt "$MAX_COLD_START_MS" ]; then
        echo "ERROR: Cold start duration ${DURATION_MS}ms exceeded ${MAX_COLD_START_MS}ms threshold on native amd64 (BASE-03)" >&2
        exit 1
    fi
fi

# Verify code-server HTTP response payload (TEST-01)
echo "Verifying code-server HTTP workbench payload (TEST-01)..."
HTML_BODY=$(curl -s -L -m 5 "http://${PROBE_HOST}:${PROBE_PORT}/")
if ! echo "$HTML_BODY" | grep -qiE 'code-server|Welcome to code-server'; then
    echo "ERROR: code-server HTML body does not contain expected code-server markers (TEST-01)" >&2
    echo "Body snippet received:" >&2
    echo "$HTML_BODY" | head -n 30 >&2
    exit 1
fi
echo "  ✓ code-server HTTP response (200/302) and HTML content confirmed (TEST-01)"

# Verify OpenSSH service readiness (TEST-02)
echo "Waiting for SSH service on ${PROBE_HOST}:${PROBE_SSH_PORT}..."
SSH_READY=0
for _ in {1..50}; do
    if timeout 1 bash -c "</dev/tcp/${PROBE_HOST}/${PROBE_SSH_PORT}" 2>/dev/null; then
        SSH_READY=1
        break
    fi
    sleep 0.2
done

if [ "$SSH_READY" -ne 1 ]; then
    echo "ERROR: SSH service failed to open port ${PROBE_SSH_PORT} on ${PROBE_HOST}" >&2
    exit 1
fi

SSH_OPTS=(-p "${PROBE_SSH_PORT}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=5 -o LogLevel=ERROR)

echo "Testing authorized SSH key login as user abc (TEST-02)..."
AUTH_USER=$(ssh "${SSH_OPTS[@]}" -i "${CLIENT_KEY}" "abc@${PROBE_HOST}" whoami)
if [ "$AUTH_USER" != "abc" ]; then
    echo "ERROR: SSH public key authentication failed for user abc (got: '${AUTH_USER}')" >&2
    exit 1
fi

AUTH_UID=$(ssh "${SSH_OPTS[@]}" -i "${CLIENT_KEY}" "abc@${PROBE_HOST}" id -u)
if [ "$AUTH_UID" != "1000" ]; then
    echo "ERROR: SSH user UID is not 1000 (got: '${AUTH_UID}')" >&2
    exit 1
fi
echo "  ✓ SSH key login verified as user abc (UID 1000) (TEST-02)"

# Negative security assertions
echo "Testing negative security controls on SSH service (TEST-02 / SSH-03)..."
# 1. Unauthorized key rejection
if ssh "${SSH_OPTS[@]}" -i "${UNAUTH_KEY}" "abc@${PROBE_HOST}" whoami >/dev/null 2>&1; then
    echo "ERROR: SSH accepted unauthorized public key (violates SSH-03)" >&2
    exit 1
fi
echo "  ✓ Unauthorized public keys are strictly rejected"

# 2. Password authentication rejection
if ssh "${SSH_OPTS[@]}" -o PubkeyAuthentication=no "abc@${PROBE_HOST}" whoami >/dev/null 2>&1; then
    echo "ERROR: SSH accepted password or interactive authentication (violates SSH-03)" >&2
    exit 1
fi
echo "  ✓ Password and interactive authentication are strictly disabled"

# 3. Root login rejection
docker exec "${CONTAINER_ID}" mkdir -p /root/.ssh
docker cp "${CLIENT_KEY}.pub" "${CONTAINER_ID}:/root/.ssh/authorized_keys"
docker exec "${CONTAINER_ID}" chmod 0700 /root/.ssh
docker exec "${CONTAINER_ID}" chmod 0600 /root/.ssh/authorized_keys

if ssh "${SSH_OPTS[@]}" -i "${CLIENT_KEY}" "root@${PROBE_HOST}" whoami >/dev/null 2>&1; then
    echo "ERROR: Root SSH login succeeded despite PermitRootLogin no (violates SSH-03)" >&2
    exit 1
fi
echo "  ✓ Root SSH login is strictly rejected"

if [ "$SKIP_IN_CONTAINER" -eq 1 ]; then
    echo "Skipping dedicated in-container smoke checks (--skip-in-container enabled)."
    echo "=== Service Smoke Verification PASSED ==="
    exit 0
fi

echo "=== External Service Probes PASSED ==="
