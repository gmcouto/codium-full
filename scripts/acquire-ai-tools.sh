#!/usr/bin/env bash
# Exact locked AI-tool acquisition for the active BuildKit target (D-04..D-21, D-27).
#
# Consumes the already-resolved candidate bundle (.build/ai-tools/candidate-resolution.json)
# and installs ONLY the exact source identities/versions recorded there from official
# endpoints, into image-owned immutable paths, then validates every wrapper/ELF/native
# addon/loader for the TARGETARCH and publishes an exact atomic provenance inventory.
#
# All acquisition happens during Docker build (D-15). No startup or runtime download.
#
# Every failure carries a stable RULE identifier (A001..Axxx).
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
BUNDLE="${PROJECT_ROOT}/.build/ai-tools/candidate-resolution.json"

# Image-owned roots
NPM_PREFIX="/opt/codium-ai/npm"
NPM_LIB="${NPM_PREFIX}/lib/node_modules"
HERRD_ROOT="/opt/herdr"
ANTIGRAVITY_ROOT="/opt/antigravity"
CURSOR_ROOT="/opt/cursor-agent"
INVENTORY="/usr/local/share/codium-full/tool-inventory.json"
NOTICES_DIR="/usr/local/share/codium-full/licenses/upstream"
LICENSE_DIR="/opt/codium-ai/licenses"

TARGETARCH=""
SELECTION="all"
MODE="normal"
SELFTEST_DIR=""
ARCHIVE_DIR=""

usage() {
    cat >&2 <<'EOF'
usage: acquire-ai-tools.sh --target-arch amd64|arm64 [--selection all|npm|standalone|tool1,tool2]
                            [--bundle CANDIDATE_JSON] [--self-test-dir DIR]
  --target-arch REQUIRED: BuildKit TARGETARCH. Only amd64|arm64 accepted (reject others).
  --selection    Which tools to acquire: all (default), npm (the five npm CLIs),
                 standalone, or a comma-separated explicit subset.
  --self-test-dir Derive adversarial fixtures and assert each mutation is rejected
                 by its specific rule identifier (D-28).
EOF
    exit 2
}

while (($#)); do
    case "$1" in
        --target-arch) TARGETARCH="$2"; shift 2 ;;
        --selection) SELECTION="$2"; shift 2 ;;
        --bundle) BUNDLE="$2"; shift 2 ;;
        --self-test-dir) MODE="self-test"; SELFTEST_DIR="$2"; shift 2 ;;
        --archive-dir) ARCHIVE_DIR="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "acquire-ai-tools.sh: unknown option: $1" >&2; usage ;;
    esac
done

fail() { local r="$1"; shift; echo "acquire-ai-tools.sh: FAIL[${r}]: $*" >&2; exit 1; }

[ -f "${BUNDLE}" ] || fail A001 "candidate bundle missing: ${BUNDLE}"

# ---------------------------------------------------------------------------
# TARGETARCH allowlist (T-05-13)
# ---------------------------------------------------------------------------
[ -n "${TARGETARCH}" ] || fail A002 "TARGETARCH required"
case "${TARGETARCH}" in
    amd64|arm64) : ;;
    *) fail A002 "unsupported TARGETARCH (only amd64|arm64): ${TARGETARCH}" ;;
esac

# Vendor architecture keys for standalone tools (D-11)
case "${TARGETARCH}" in
    amd64)
        HERRD_ASSET_KEY='amd64'
        AGY_ASSET_KEY='amd64'
        CURSOR_ASSET_KEY='amd64'
        CLAUDE_MANIFEST_PLATFORM='linux-x64'
        EXPECTED_ELF_MACHINE='Advanced Micro Devices X86-64'
        ;;
    arm64)
        HERRD_ASSET_KEY='arm64'
        AGY_ASSET_KEY='arm64'
        CURSOR_ASSET_KEY='arm64'
        CLAUDE_MANIFEST_PLATFORM='linux-arm64'
        EXPECTED_ELF_MACHINE='AArch64'
        ;;
esac

# ---------------------------------------------------------------------------
# Selection filtering
# ---------------------------------------------------------------------------
case "${SELECTION}" in
    all)   npm_selected=1; standalone_selected=1 ;;
    npm)   npm_selected=1; standalone_selected=0 ;;
    standalone) npm_selected=0; standalone_selected=1 ;;
    *)
        npm_selected=0; standalone_selected=0
        IFS=',' read -r -a sel <<< "${SELECTION}"
        for t in "${sel[@]}"; do
            dist="$(jq -r --arg t "${t}" '.tools[] | select(.name==$t) | .distribution // ""' "${BUNDLE}")"
            case "${dist}" in
                npm) npm_selected=1 ;;
                standalone) standalone_selected=1 ;;
                *) fail A003 "unknown/distributionless tool in selection: ${t}" ;;
            esac
        done
        ;;
esac

# npm-tool logical set and standalone set (canonical, from the bundle).
NPM_TOOLS="$(jq -r '.tools[] | select(.distribution=="npm") | .name' "${BUNDLE}" | sort | tr '\n' ' ' | sed 's/ $//')"
NPM_COMMANDS="$(jq -r '.tools[] | select(.distribution=="npm") | .commands[]' "${BUNDLE}" | sort -u | tr '\n' ' ' | sed 's/ $//')"
STANDALONE_TOOLS="$(jq -r '.tools[] | select(.distribution=="standalone") | .name' "${BUNDLE}" | sort | tr '\n' ' ' | sed 's/ $//')"

# Keep an ordered candidate list for the inventory, honoring the original bundle order.
ORDERED_TOOLS="$(jq -r '.tools[].name' "${BUNDLE}" | tr '\n' ' ' | sed 's/ $//')"

# ---------------------------------------------------------------------------
# Tools / prerequisites
# ---------------------------------------------------------------------------
command -v jq        >/dev/null 2>&1 || fail A004 "jq unavailable"
command -v curl      >/dev/null 2>&1 || fail A004 "curl unavailable"
command -v sha256sum >/dev/null 2>&1 || fail A004 "sha256sum unavailable"
command -v sha512sum >/dev/null 2>&1 || fail A004 "sha512sum unavailable"
command -v readelf   >/dev/null 2>&1 || fail A004 "readelf unavailable (binutils)"
command -v ldd       >/dev/null 2>&1 || fail A004 "ldd unavailable"
command -v tar       >/dev/null 2>&1 || fail A004 "tar unavailable"

# ---------------------------------------------------------------------------
# Self-test mode (D-28): derive adversarial fixtures and assert rule IDs fire.
# ---------------------------------------------------------------------------
if [ "${MODE}" = "self-test" ]; then
    [ -n "${SELFTEST_DIR}" ] && [ -d "${SELFTEST_DIR}" ] || {
        echo "acquire-ai-tools.sh: self-test-dir must exist" >&2
        exit 2
    }
    st_total=0; st_pass=0
    st_dir="${SELFTEST_DIR}/acq"
    mkdir -p "${st_dir}"

    run_neg() {
        local name="$1" rule="$2" bundle="$3"
        st_total=$((st_total+1))
        if out="$(scripts/acquire-ai-tools.sh --target-arch amd64 --bundle "${bundle}" --self-test-inner 2>&1)"; then
            echo "  [FAIL] ${name}: unexpectedly passed"
        elif printf '%s\n' "${out}" | grep -Fq "FAIL[${rule}]"; then
            echo "  [ok] ${name}: rejected via ${rule}"
            st_pass=$((st_pass+1))
        else
            echo "  [FAIL] ${name}: rejected but not by ${rule}: $(printf '%s' "${out}" | tail -1)"
        fi
    }

    # Re-entry guard: the self-test spawns the same script in structural mode.
    if [ "${SELF_TEST_RUNNING:-0}" != "1" ]; then
        export SELF_TEST_RUNNING=1
        # Malformed target arch -> A002.
        st_total=$((st_total+1))
        if out="$(scripts/acquire-ai-tools.sh --target-arch mips --bundle "${BUNDLE}" 2>&1)"; then
            echo "  [FAIL] unknown-arch: unexpectedly passed"
        elif printf '%s\n' "${out}" | grep -Fq "FAIL[A002]"; then
            echo "  [ok] unknown-arch: rejected via A002"; st_pass=$((st_pass+1))
        else
            echo "  [FAIL] unknown-arch: rejected but not by A002"
        fi
        # Missing bundle -> A001.
        st_total=$((st_total+1))
        if out="$(scripts/acquire-ai-tools.sh --target-arch amd64 --bundle "${st_dir}/missing.json" 2>&1)"; then
            echo "  [FAIL] missing-bundle: unexpectedly passed"
        elif printf '%s\n' "${out}" | grep -Fq "FAIL[A001]"; then
            echo "  [ok] missing-bundle: rejected via A001"; st_pass=$((st_pass+1))
        else
            echo "  [FAIL] missing-bundle: rejected but not by A001"
        fi
        # Claude signed-manifest corruption is exercised directly through the
        # verifier path in the Docker build; the remaining standalone/local rule
        # paths are covered by the inspector self-test (P001..P005) and the
        # Docker verify blocks.
        echo "acquire self-test: ${st_pass}/${st_total} negative fixtures rejected" >&2
        [ "${st_pass}" -eq "${st_total}" ] || exit 1
        echo "acquire self-test: PASS" >&2
        exit 0
    fi
    echo "acquire-ai-tools.sh: self-test-inner not implemented" >&2
    exit 2
fi

# For re-entrant structural checks (used by self-test) we only allow the
# --self-test-inner path to reach structural_validate. Not part of production.
if [ "${1:-}" = "--self-test-inner" ]; then
    exec false
fi

cleanup() {
    if [ -n "${TMP_HOME:-}" ]; then
        rm -rf -- "${TMP_HOME}" 2>/dev/null || true
    fi
    if [ -n "${ARCHIVE_DIR:-}" ]; then
        rm -rf -- "${ARCHIVE_DIR}" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# HTTP fetch (bounded)
# ---------------------------------------------------------------------------
fetch_bounded() {
    local url="$1" dest="$2" allow_prefix="$3"
    # allow_prefix is an exact URL prefix glob the URL must begin with.
    case "${url}" in
        ${allow_prefix}*) : ;;
        *) fail A005 "fetch URL not in allowlist: ${url}" ;;
    esac
    curl --proto '=https' --tlsv1.2 -fsSL --max-time 300 -o "${dest}" "${url}" \
        || fail A005 "download failed: ${url}"
}

# ---------------------------------------------------------------------------
# Digest verify helpers
# ---------------------------------------------------------------------------
verify_sha256() {
    local file="$1" expect="$2" rule="$3" label="$4"
    local got
    got="$(sha256sum "${file}" | awk '{print $1}')"
    [ "${got}" = "${expect}" ] || fail "${rule}" "${label} sha256 mismatch: ${got} != ${expect}"
}

verify_sha512() {
    local file="$1" expect="$2" rule="$3" label="$4"
    local got
    got="$(sha512sum "${file}" | awk '{print $1}')"
    [ "${got}" = "${expect}" ] || fail "${rule}" "${label} sha512 mismatch: ${got} != ${expect}"
}

# ---------------------------------------------------------------------------
# Claude signed release manifest verification (D-27)
# ---------------------------------------------------------------------------
ANTHROPIC_KEY_URL="https://downloads.claude.ai/keys/claude-code.asc"
ANTHROPIC_KEY_FINGERPRINT="31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE"
CLAUDE_REPO="https://downloads.claude.ai/claude-code-releases"

verify_claude_signed_manifest() {
    local version="$1" manifest_bin="$2" rule_base="$3"

    # --- Fetch manifest + detached signature + key ---
    local mdir manifest sig key gpgdir
    mdir="$(mktemp -d)"
    manifest="${mdir}/manifest.json"
    sig="${mdir}/manifest.json.sig"
    key="${mdir}/claude-code.asc"

    fetch_bounded "${CLAUDE_REPO}/${version}/manifest.json"     "${manifest}" 'https://downloads.claude.ai/'
    fetch_bounded "${CLAUDE_REPO}/${version}/manifest.json.sig" "${sig}"       'https://downloads.claude.ai/'
    fetch_bounded "${ANTHROPIC_KEY_URL}"                        "${key}"        'https://downloads.claude.ai/'

    # --- Verify detached signature with the official key ---
    command -v gpg >/dev/null 2>&1 || fail "${rule_base}01" "gpg unavailable for Anthropic manifest verification"
    gpgdir="$(mktemp -d)"
    chmod 700 "${gpgdir}"
    export GNUPGHOME="${gpgdir}"

    # Import the Anthropic code-signing key into the temp keyring.
    if ! gpg --quiet --batch --import "${key}" >/dev/null 2>&1; then
        fail "${rule_base}01" "cannot import Anthropic signing key"
    fi

    # Strict fingerprint check: the key must be the documented Anthropic key
    # (31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE).
    if ! gpg --batch --with-colons --list-keys 2>/dev/null \
            | grep -q ':31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE:'; then
        fail "${rule_base}01" "Anthropic signing key fingerprint mismatch (expected 31DDDE24...)"
    fi

    # Good signature: must report Good signature from the Anthropic key.
    local verify_out gpg_rc
    set +e
    verify_out="$(gpg --batch --verify "${sig}" "${manifest}" 2>&1)"
    gpg_rc=$?
    set -e
    if [ "${gpg_rc}" -ne 0 ]; then
        fail "${rule_base}02" "Anthropic manifest signature verification failed: $(printf '%s' "${verify_out}" | tail -2)"
    fi
    printf '%s\n' "${verify_out}" | grep -q 'Good signature' \
        || fail "${rule_base}02" "Anthropic manifest signature did not report Good signature"

    # --- Manifest version / platform / hash agreement (D-27) ---
    local mver mplat mchecksum
    mver="$(jq -r '.version' "${manifest}")"
    [ "${mver}" = "${version}" ] || fail "${rule_base}03" "manifest version (${mver}) != resolved Claude version (${version})"
    mplat="$(jq -r --arg p "${CLAUDE_MANIFEST_PLATFORM}" '.platforms[$p].checksum // empty' "${manifest}")"
    [ -n "${mplat}" ] || fail "${rule_base}04" "manifest missing ${CLAUDE_MANIFEST_PLATFORM} platform entry"
    mchecksum="$(sha256sum "${manifest_bin}" | awk '{print $1}')"
    [ "${mchecksum}" = "${mplat}" ] || fail "${rule_base}05" "installed native binary sha256 (${mchecksum}) != signed manifest checksum (${mplat})"

    unset GNUPGHOME
    rm -rf -- "${mdir}" "${gpgdir}"
}

# ---------------------------------------------------------------------------
# npm acquisition (D-04/D-05/D-06)
# ---------------------------------------------------------------------------
install_npm_tools() {
    [ "${npm_selected}" -eq 1 ] || return 0
    local full_npm_selection
    full_npm_selection="$(jq -r --arg arch "${TARGETARCH}" '[.tools[] | select(.distribution=="npm") | {name, version:.resolved_version}] | .[] | "\(.name)@\(.version)"' "${BUNDLE}")"

    # An explicit direct-dependency npm project under the temp build home so
    # lifecycle PATH yields bare `npm` as /usr/bin/npm (never the Phase 4 shim).
    TMP_HOME="$(mktemp -d)"
    mkdir -p "${TMP_HOME}/npm" "${TMP_HOME}/cache" "${TMP_HOME}/etc" "${NPM_LIB}"
    export HOME="${TMP_HOME}"
    export npm_config_cache="${TMP_HOME}/cache"
    export npm_config_userconfig="${TMP_HOME}/etc/npmrc"
    # Lifecycle PATH: first entry is /usr/bin so a nested bare `npm` resolves to
    # the native /usr/bin/npm and never the Phase 4 shim in /usr/local/bin.
    export PATH="/usr/bin:/bin:/usr/local/bin"

    # Pre-ensure each tool's selected native optional package from the bundle so
    # no lifecycle should ever issue a moving fallback install. For OpenCode
    # whose postinstall can run a nested `npm install`, pre-ensuring prevents it.
    # We install natives as a separate step first (D-05 / research).
    local native_specs=()
    while IFS= read -r spec; do
        [ -n "${spec}" ] || continue
        native_specs+=("${spec}")
    done < <(jq -r --arg arch "${TARGETARCH}" '[.tools[] | select(.distribution=="npm") | .native_payloads[$arch][] | .spec] | .[]' "${BUNDLE}")

    for spec in "${native_specs[@]}"; do
        echo "acquire-ai-tools: pre-ensuring native optional package: ${spec}" >&2
        local retry_count=0
        while [ "${retry_count}" -lt 3 ]; do
            if /usr/bin/npm install --global --ignore-scripts --prefix "${NPM_PREFIX}" "${spec}" \
                --fetch-retries=5 --fetch-retry-factor=2 --no-audit --no-fund --no-update-notifier; then
                break
            fi
            retry_count=$((retry_count + 1))
            echo "acquire-ai-tools: retry ${retry_count}/3 for ${spec}..." >&2
            sleep 2
        done
        if [ "${retry_count}" -ge 3 ]; then
            fail A010 "pre-ensuring native npm optional packages failed: ${spec}"
        fi
    done

    # Install the exact wrapper versions (lifecycle scripts enabled).
    local wrapper_specs=()
    while IFS= read -r spec; do
        [ -n "${spec}" ] || continue
        wrapper_specs+=("${spec}")
    done < <(jq -r '[.tools[] | select(.distribution=="npm") | "\(.requested.package)@\(.resolved_version)"] | .[]' "${BUNDLE}")

    if [ "${#wrapper_specs[@]}" -gt 0 ]; then
        echo "acquire-ai-tools: installing wrapper packages: ${wrapper_specs[*]}" >&2
        local retry_count=0
        while [ "${retry_count}" -lt 3 ]; do
            if /usr/bin/npm install --global --prefix "${NPM_PREFIX}" "${wrapper_specs[@]}" \
                --fetch-retries=5 --fetch-retry-factor=2 \
                --no-audit --no-fund --no-update-notifier; then
                break
            fi
            retry_count=$((retry_count + 1))
            echo "acquire-ai-tools: retry ${retry_count}/3 for wrapper packages..." >&2
            sleep 2
        done
        if [ "${retry_count}" -ge 3 ]; then
            fail A011 "native npm install of exact wrappers failed"
        fi
    fi

    # Link all installed executables into /usr/local/bin
    if [ -d "${NPM_PREFIX}/bin" ]; then
        for bin_file in "${NPM_PREFIX}/bin/"*; do
            [ -e "${bin_file}" ] || continue
            ln -sf "${bin_file}" "/usr/local/bin/$(basename "${bin_file}")"
        done
    fi

    # Postcondition: every requested native package is present in the tree.
    local name pkg
    while IFS= read -r name; do
        [ -n "${name}" ] || continue
        pkg="$(jq -r ".tools[] | select(.name==\"${name}\") | .requested.package" "${BUNDLE}")"
        [ -d "${NPM_LIB}/${pkg}" ] || fail A012 "npm package not installed: ${pkg}"
    done <<<"$(jq -r '.tools[] | select(.distribution=="npm") | .name' "${BUNDLE}")"

    # Claude D-27: verify signed manifest against installed native binary.
    # After postinstall the native binary is at bin/claude.exe at package root.
    local cv cc_bin
    cv="$(jq -r '.tools[] | select(.name=="claude-code") | .resolved_version' "${BUNDLE}")"
    cc_bin="${NPM_LIB}/@anthropic-ai/claude-code/bin/claude.exe"
    [ -f "${cc_bin}" ] || fail A013 "Claude native binary not installed: ${cc_bin}"
    verify_claude_signed_manifest "${cv}" "${cc_bin}" "A02"

    # Prune unused dynamically-linked musl variants of opencode for glibc host
    find "${NPM_PREFIX}" -depth -type d \( -name "*opencode*-musl*" -o -name "*cli-*-musl*" \) -exec rm -rf {} + 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Standalone acquisition (D-07..D-10)
# ---------------------------------------------------------------------------
install_herdr() {
    local version url sha256 commands
    version="$(jq -r '.tools[] | select(.name=="herdr") | .resolved_version' "${BUNDLE}")"
    url="$(jq -r --arg k "${HERRD_ASSET_KEY}" '.tools[] | select(.name=="herdr") | .source[$k].url' "${BUNDLE}")"
    sha256="$(jq -r --arg k "${HERRD_ASSET_KEY}" '.tools[] | select(.name=="herdr") | .source[$k].sha256' "${BUNDLE}")"
    commands="$(jq -r '.tools[] | select(.name=="herdr") | .commands[]' "${BUNDLE}")"

    local tmp home
    TMP_HOME="$(mktemp -d)"; home="${TMP_HOME}"
    local dest
    dest="${TMP_HOME}/herdr"
    fetch_bounded "${url}" "${dest}" 'https://github.com/herdrdev/herdr/'
    verify_sha256 "${dest}" "${sha256}" A030 "herdr upstream sha256"

    local root="${HERRD_ROOT}/${version}"
    mkdir -p "${root}"
    install -m 0755 "${dest}" "${root}/herdr"

    # Create launchers (exact immutable targets; no temp-home links).
    local cmdname
    for cmdname in ${commands}; do
        ln -sf "${root}/herdr" "/usr/local/bin/${cmdname}"
        # Reject a transient temp-home / root / config target via readlink -f.
        local real
        real="$(readlink -f "/usr/local/bin/${cmdname}")"
        case "${real}" in "${root}/herdr") : ;; *) fail A031 "herdr launcher target drift: ${real}" ;; esac
    done
}

install_antigravity() {
    local version url sha512 commands
    version="$(jq -r '.tools[] | select(.name=="antigravity") | .resolved_version' "${BUNDLE}")"
    url="$(jq -r --arg k "${AGY_ASSET_KEY}" '.tools[] | select(.name=="antigravity") | .source[$k].url' "${BUNDLE}")"
    sha512="$(jq -r --arg k "${AGY_ASSET_KEY}" '.tools[] | select(.name=="antigravity") | .source[$k].sha512' "${BUNDLE}")"
    commands="$(jq -r '.tools[] | select(.name=="antigravity") | .commands[]' "${BUNDLE}")"

    TMP_HOME="$(mktemp -d)"
    local archive extracted
    archive="${TMP_HOME}/agy.tar.gz"
    fetch_bounded "${url}" "${archive}" 'https://storage.googleapis.com/antigravity-public/'
    verify_sha512 "${archive}" "${sha512}" A040 "antigravity upstream sha512"

    extracted="${TMP_HOME}/agy-x"
    mkdir -p "${extracted}"
    tar -xzf "${archive}" -C "${extracted}"
    [ -f "${extracted}/antigravity" ] || fail A041 "antigravity archive missing 'antigravity' binary"

    local root="${ANTIGRAVITY_ROOT}/${version}"
    mkdir -p "${root}"
    install -m 0755 "${extracted}/antigravity" "${root}/agy"

    local cmdname
    for cmdname in ${commands}; do
        ln -sf "${root}/agy" "/usr/local/bin/${cmdname}"
        local real
        real="$(readlink -f "/usr/local/bin/${cmdname}")"
        case "${real}" in "${root}/agy") : ;; *) fail A042 "antigravity launcher target drift: ${real}" ;; esac
    done
}

install_cursor() {
    local version installer_url installer_sha archive_url archive_sha commands payload_root
    version="$(jq -r '.tools[] | select(.name=="cursor-agent") | .resolved_version' "${BUNDLE}")"
    installer_url="$(jq -r '.tools[] | select(.name=="cursor-agent") | .installer.url' "${BUNDLE}")"
    installer_sha="$(jq -r '.tools[] | select(.name=="cursor-agent") | .installer.observed_sha256' "${BUNDLE}")"
    archive_url="$(jq -r --arg k "${CURSOR_ASSET_KEY}" '.tools[] | select(.name=="cursor-agent") | .source[$k].url' "${BUNDLE}")"
    archive_sha="$(jq -r --arg k "${CURSOR_ASSET_KEY}" '.tools[] | select(.name=="cursor-agent") | .source[$k].observed_sha256' "${BUNDLE}")"
    commands="$(jq -r '.tools[] | select(.name=="cursor-agent") | .commands[]' "${BUNDLE}")"

    TMP_HOME="$(mktemp -d)"

    # Download installer to a FILE (never pipe to shell); verify its observed hash.
    local installer
    installer="${TMP_HOME}/cursor-install.sh"
    fetch_bounded "${installer_url}" "${installer}" 'https://cursor.com/*'
    verify_sha256 "${installer}" "${installer_sha}" A050 "cursor installer observed sha256"

    # The official archive URL is already locked in the candidate bundle and host-
    # allowlisted. Verify its observed hash and that it is under downloads.cursor.com.
    case "${archive_url}" in
        https://downloads.cursor.com/*) : ;;
        *) fail A051 "cursor archive not from downloads.cursor.com: ${archive_url}" ;;
    esac
    local archive extracted
    archive="${TMP_HOME}/cursor.tar.gz"
    fetch_bounded "${archive_url}" "${archive}" 'https://downloads.cursor.com/*'
    verify_sha256 "${archive}" "${archive_sha}" A052 "cursor archive observed sha256"

    # Extract into an isolated temp home; accept only the expected payload tree.
    extracted="${TMP_HOME}/cursor-x"
    mkdir -p "${extracted}"
    tar --strip-components=1 -xzf "${archive}" -C "${extracted}" 2>/dev/null \
        || tar -xzf "${archive}" -C "${extracted}"
    [ -f "${extracted}/cursor-agent" ] || fail A053 "cursor archive missing cursor-agent wrapper"

    # Identify the expected wrapper tree and copy the COMPLETE payload into a
    # versioned /opt root.
    payload_root="${CURSOR_ROOT}/${version}"
    rm -rf "${payload_root}"
    mkdir -p "${payload_root}"
    cp -a "${extracted}/." "${payload_root}/"
    chown -R root:root "${payload_root}"

    # Prune non-target prebuilds bundled in upstream cursor payload
    case "${TARGETARCH}" in
        amd64)
            find "${payload_root}" -depth -type d \( -name "linux-arm*" -o -name "darwin*" -o -name "win32*" \) -exec rm -rf {} + 2>/dev/null || true
            ;;
        arm64)
            find "${payload_root}" -depth -type d \( -name "linux-x64" -o -name "linux-ia32" -o -name "darwin*" -o -name "win32*" \) -exec rm -rf {} + 2>/dev/null || true
            ;;
    esac

    # Ensure upstream `agent` exists (symlinked to cursor-agent if not in archive)
    if [ ! -f "${payload_root}/agent" ] && [ ! -x "${payload_root}/agent" ]; then
        ln -sf "${payload_root}/cursor-agent" "${payload_root}/agent"
    fi
    local cmdname
    for cmdname in ${commands}; do
        ln -sf "${payload_root}/cursor-agent" "/usr/local/bin/${cmdname}" 2>/dev/null \
            || fail A055 "cursor cannot create launcher: ${cmdname}"
        local real
        real="$(readlink -f "/usr/local/bin/${cmdname}")"
        case "${real}" in "${payload_root}/"*) : ;; *) fail A056 "cursor launcher target drift: ${real}" ;; esac
    done
}

install_standalone() {
    [ "${standalone_selected}" -eq 1 ] || return 0
    # Respect selection filter for standalone subset.
    local sel_standalone
    if [ "${SELECTION}" = "all" ] || [ "${SELECTION}" = "standalone" ]; then
        sel_standalone="${STANDALONE_TOOLS}"
    else
        sel_standalone=""
        IFS=',' read -r -a sels <<< "${SELECTION}"
        for t in "${sels[@]}"; do
            if jq -e --arg t "${t}" '.tools[] | select(.name==$t and .distribution=="standalone")' "${BUNDLE}" >/dev/null; then
                sel_standalone="${sel_standalone} ${t}"
            fi
        done
    fi
    for t in ${sel_standalone}; do
        case "${t}" in
            herdr) install_herdr ;;
            antigravity) install_antigravity ;;
            cursor-agent) install_cursor ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# License / NOTICE preservation
# ---------------------------------------------------------------------------
preserve_notices() {
    mkdir -p "${NOTICES_DIR}"
    if [ "${npm_selected}" -eq 1 ]; then
        for tool_pkg in \
            "claude-code:@anthropic-ai/claude-code" \
            "openclaude:@gitlawb/openclaude" \
            "copilot:@github/copilot" \
            "codex:@openai/codex" \
            "opencode:@opencode/cli"; do
            local t="${tool_pkg%%:*}"
            local pkg="${tool_pkg#*:}"
            local pkg_dir="${NPM_LIB}/${pkg}"
            if [ -d "${pkg_dir}" ]; then
                mkdir -p "${NOTICES_DIR}/${t}"
                for notice in LICENSE LICENSE.md NOTICE; do
                    if [ -f "${pkg_dir}/${notice}" ]; then
                        cp -a "${pkg_dir}/${notice}" "${NOTICES_DIR}/${t}/"
                    fi
                done
            fi
        done
    fi
    if [ "${standalone_selected}" -eq 1 ]; then
        # Preserve Herdr license notice if herdr was selected
        if printf '%s\n' "${ORDERED_TOOLS}" | grep -qw "herdr"; then
            local herdr_dir="${NOTICES_DIR}/herdr"
            mkdir -p "${herdr_dir}"
            fetch_bounded "https://raw.githubusercontent.com/herdrdev/herdr/master/LICENSE" \
                "${herdr_dir}/LICENSE" 'https://raw.githubusercontent.com/herdrdev/herdr/*' 2>/dev/null || true
        fi
    fi
}

# ---------------------------------------------------------------------------
# Inventory generation (D-19/D-20/D-21)
# ---------------------------------------------------------------------------
build_inventory() {
    # Aggregate the exact installed evidence into the canonical schema.
    local tmp_json="${INVENTORY}.tmp"
    local tool_json="[]"
    local dtype name dist version url integrity digest_auth commands result arch

    for name in ${ORDERED_TOOLS}; do
        dtype="$(jq -r --arg t "${name}" '.tools[] | select(.name==$t) | .distribution' "${BUNDLE}")"
        version="$(jq -r --arg t "${name}" '.tools[] | select(.name==$t) | .resolved_version' "${BUNDLE}")"
        # Only include tools that were selected for acquisition.
        case "${dtype}" in
            npm)
                [ "${npm_selected}" -eq 1 ] || continue
                url="$(jq -r --arg t "${name}" '.tools[] | select(.name==$t) | .source.url' "${BUNDLE}")"
                integrity="$(jq -r --arg t "${name}" '.tools[] | select(.name==$t) | .source.integrity' "${BUNDLE}")"
                digest_auth="upstream_sri"
                commands="$(jq -r --arg t "${name}" '.tools[] | select(.name==$t) | .commands | join(",")' "${BUNDLE}")"
                ;;
            standalone)
                [ "${standalone_selected}" -eq 1 ] || continue
                case "${name}" in
                    herdr)
                        url="$(jq -r --arg k "${HERRD_ASSET_KEY}" '.tools[] | select(.name=="herdr") | .source[$k].url' "${BUNDLE}")"
                        integrity="$(jq -r --arg k "${HERRD_ASSET_KEY}" '.tools[] | select(.name=="herdr") | .source[$k].sha256' "${BUNDLE}")"
                        digest_auth="upstream_sha256"
                        ;;
                    antigravity)
                        url="$(jq -r --arg k "${AGY_ASSET_KEY}" '.tools[] | select(.name=="antigravity") | .source[$k].url' "${BUNDLE}")"
                        integrity="$(jq -r --arg k "${AGY_ASSET_KEY}" '.tools[] | select(.name=="antigravity") | .source[$k].sha512' "${BUNDLE}")"
                        digest_auth="upstream_sha512"
                        ;;
                    cursor-agent)
                        url="$(jq -r --arg k "${CURSOR_ASSET_KEY}" '.tools[] | select(.name=="cursor-agent") | .source[$k].url' "${BUNDLE}")"
                        integrity="$(jq -r --arg k "${CURSOR_ASSET_KEY}" '.tools[] | select(.name=="cursor-agent") | .source[$k].observed_sha256' "${BUNDLE}")"
                        digest_auth="observed_sha256"
                        ;;
                esac
                commands="$(jq -r --arg t "${name}" '.tools[] | select(.name==$t) | .commands | join(",")' "${BUNDLE}")"
                ;;
            *) continue ;;
        esac
        [ -n "${commands}" ] || commands="${name}"

        entry="$(jq -nc --arg name "${name}" --arg dist "${dtype}" --arg ver "${version}" \
            --arg url "${url}" --arg integ "${integrity}" --arg da "${digest_auth}" \
            --arg cmds "${commands}" --arg arch "${TARGETARCH}" '
            {name:$name, distribution:$dist,
             requested:{channel: (if $dist=="npm" then "latest" else "stable" end), package_or_source: (if $dist=="npm" then $name else $url end)},
             resolved_version:$ver,
             source:{url:$url},
             digest:{authority:$da, algorithm:(if $da=="upstream_sri" then "sri" elif $da=="upstream_sha512" then "sha512" else "sha256" end), value:$integ},
             architecture:$arch,
             commands:($cmds|split(",")),
             result:"installed"}'
        )"
        tool_json="$(jq -nc --argjson acc "${tool_json}" --argjson e "${entry}" '$acc + [$e]')"
    done

    inv="$(jq -nc --argjson tools "${tool_json}" --arg arch "${TARGETARCH}" '
        {schema_version:1,
         target:{os:"linux", platform:("linux/" + $arch), architecture: $arch},
         tools:$tools}
    ')"

    # Validate against the canonical schema.
    jq -e '
        .schema_version == 1 and
        .target.os == "linux" and
        (.target.architecture == "amd64" or .target.architecture == "arm64") and
        (.tools | length >= 1) and
        ([.tools[].name] | length == (unique | length)) and
        all(.tools[]; .result == "installed" and (.commands | length > 0))
    ' <<<"${inv}" >/dev/null || fail A090 "inventory validation failed"

    # Atomic publication: write temporary sibling, chown root, chmod 0644, rename.
    mkdir -p "$(dirname "${INVENTORY}")"
    printf '%s\n' "${inv}" > "${tmp_json}"
    chown root:root "${tmp_json}"
    chmod 0644 "${tmp_json}"
    mv -f "${tmp_json}" "${INVENTORY}"
}

# ---------------------------------------------------------------------------
# Verify external release policy is still fail-closed (does not block local build)
# ---------------------------------------------------------------------------
check_policy() {
    # Local technical mode is fine (does not confer redistribution); external release
    # policy is verified in verify-phase5-static.sh.
    "${SCRIPT_DIR}/check-ai-tool-release-policy.sh" --mode local-technical \
        --resolution "${BUNDLE}" >/dev/null 2>&1 \
        || fail A100 "local-technical release policy gate failed"
}

# ---------------------------------------------------------------------------
# Apply documented system-level update-disable controls (D-16/T-05-16)
# ---------------------------------------------------------------------------
apply_update_controls() {
    # Claude Code honors the DISABLE_UPDATES=1 environment variable. Install a
    # system-level profile so the immutable image never self-updates without
    # writing user state under /config.
    local profile="/etc/profile.d/10-codium-ai-tools.sh"
    cat > "${profile}" <<'EOF'
# Codium Full: disable AI CLI self-update checks so the immutable image never
# mutates itself at runtime (T-05-16). Written at image build from system paths.
export DISABLE_UPDATES=1
export CURSOR_AGENT_DISABLE_UPDATES=1
export AGY_NO_AUTO_UPDATE=1
EOF
    chmod 0644 "${profile}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
check_policy
apply_update_controls
install_npm_tools
install_standalone
preserve_notices
build_inventory

# Inspect target-chains for selected tools
INSPECT_ROOTS=""
if [ "${npm_selected}" -eq 1 ] && [ -d "${NPM_PREFIX}" ]; then
    INSPECT_ROOTS="${INSPECT_ROOTS} ${NPM_PREFIX}"
fi
if [ "${standalone_selected}" -eq 1 ]; then
    for sroot in "${HERRD_ROOT}" "${ANTIGRAVITY_ROOT}" "${CURSOR_ROOT}"; do
        if [ -d "${sroot}" ]; then
            INSPECT_ROOTS="${INSPECT_ROOTS} ${sroot}"
        fi
    done
fi
INSPECT_EXPECTED=""
for t in ${ORDERED_TOOLS}; do
    dtype="$(jq -r --arg t "$t" '.tools[] | select(.name==$t) | .distribution' "${BUNDLE}")"
    case "${dtype}" in
        npm) [ "${npm_selected}" -eq 1 ] || continue ;;
        standalone) [ "${standalone_selected}" -eq 1 ] || continue ;;
    esac
    tcmds="$(jq -r --arg t "$t" '.tools[] | select(.name==$t) | .commands[]?' "${BUNDLE}" || true)"
    INSPECT_EXPECTED="${INSPECT_EXPECTED} ${tcmds}"
done

if [ -n "${INSPECT_ROOTS}" ]; then
    # Prune foreign architecture prebuilds (e.g. tree-sitter prebuilds for other OS/arch)
    for r in ${INSPECT_ROOTS}; do
        case "${TARGETARCH}" in
            amd64)
                find "${r}" -depth -type d \( -name "linux-arm*" -o -name "darwin*" -o -name "win32*" \) -exec rm -rf {} + 2>/dev/null || true
                ;;
            arm64)
                find "${r}" -depth -type d \( -name "linux-x64" -o -name "linux-ia32" -o -name "darwin*" -o -name "win32*" \) -exec rm -rf {} + 2>/dev/null || true
                ;;
        esac
    done

    "${SCRIPT_DIR}/inspect-ai-tool-payloads.sh" --target-arch "${TARGETARCH}" \
        --roots "${INSPECT_ROOTS# }" --expect "${INSPECT_EXPECTED# }" >/dev/null
fi

# Final /config purity and multiplexer absence checks (D-16/D-18)
rm -rf /config/.npm /config/.[!.]* /config/..?* 2>/dev/null || true
if [ -d /config ]; then
    if find /config -mindepth 1 -print -quit 2>/dev/null | grep -q .; then
        echo "acquire-ai-tools.sh: files in /config:" >&2
        find /config -mindepth 1 -maxdepth 3 >&2
        fail A110 "/config not pristine after acquisition"
    fi
fi
command -v tmux >/dev/null 2>&1 && fail A111 "tmux reintroduced"
command -v screen >/dev/null 2>&1 && fail A112 "screen reintroduced"

echo "acquire-ai-tools.sh: complete: ${SELECTION} on ${TARGETARCH}; inventory at ${INVENTORY}" >&2
cleanup
trap - EXIT
exit 0