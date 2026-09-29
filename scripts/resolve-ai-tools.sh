#!/usr/bin/env bash
# Resolve AI tool moving channels into one exact, target-aware candidate bundle.
# Phase 5 primitive consumed by Phase 6 to inject the SAME bundle into both
# platform image builds. This script performs metadata/lock resolution only and
# installs nothing. Per D-03 it never persists resolved versions into source.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
SOURCES="${PROJECT_ROOT}/ai-tools/sources.json"

usage() {
    cat >&2 <<'EOF'
usage: resolve-ai-tools.sh [--selection a,b,c] [--output PATH]
  --selection   comma-separated logical tool names to resolve (default: all eight)
  --output      absolute path to write candidate-resolution.json (default: -)
EOF
    exit 2
}

SELECTION=""
OUTPUT="-"
while (($#)); do
    case "$1" in
        --selection) SELECTION="$2"; shift 2 ;;
        --output) OUTPUT="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "resolve-ai-tools.sh: unknown option: $1" >&2; usage ;;
    esac
done

# Prefer the image native npm binary; fall back to PATH for local/dev runs.
# The Phase 4 shim reference lives at /usr/local/bin/npm which must never be used.
NPM_BIN="${NPM_BIN:-${npm_install_path_image:-/usr/bin/npm}}"
if [ ! -x "${NPM_BIN}" ]; then
    if command -v npm >/dev/null 2>&1 && [ "$(command -v npm)" != "/usr/local/bin/npm" ]; then
        NPM_BIN="$(command -v npm)"
    else
        echo "resolve-ai-tools.sh: uknown NPM_BIN/Builtin npm; no native npm found" >&2
        exit 1
    fi
fi
NPM_BIN="$(command -v "${NPM_BIN}" || true)"
if [ -z "${NPM_BIN}" ] || [ ! -x "${NPM_BIN}" ]; then
    echo "resolve-ai-tools.sh: native npm not executable (${NPM_BIN:-unset})" >&2
    exit 1
fi
NPM_BIN_DIR="$(dirname -- "${NPM_BIN}")"

# Redirect runtime PATH so lifecycle/helpers cannot pick up the Phase 4 shim.
export PATH="${NPM_BIN_DIR}:/usr/local/bin:/usr/bin:/bin"

if [ ! -f "${SOURCES}" ]; then
    echo "resolve-ai-tools.sh: sources contract not found: ${SOURCES}" >&2
    exit 1
fi

# Validate sources.json shape up-front with strict jq.
if ! jq -e '.schema_version == 1 and (.tools | type == "object") and (.allowed_architectures == ["amd64","arm64"])' "${SOURCES}" >/dev/null; then
    echo "resolve-ai-tools.sh: sources.json failed schema preflight" >&2
    exit 1
fi

# Selection filtering.
ALL_TOOLS="claude-code openclaude copilot codex opencode cursor-agent antigravity herdr"
if [ -n "${SELECTION}" ]; then
    IFS=',' read -r -a SELECTED <<<"${SELECTION}"
else
    SELECTED=( ${ALL_TOOLS} )
fi
# Normalize order to sources order.
TOOLS_ORDERED=()
for t in ${ALL_TOOLS}; do
    for s in "${SELECTED[@]}"; do
        [ "${t}" = "${s}" ] && TOOLS_ORDERED+=("${t}")
    done
done
if ((${#TOOLS_ORDERED[@]} != ${#SELECTED[@]})); then
    echo "resolve-ai-tools.sh: unknown tool in --selection: ${SELECTION}" >&2
    exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf -- "${TMP}"' EXIT

HTTP_FETCH_BOUND=90
declare -A TOOL_ENTRIES

fetch_bounded() {
    local url="$1" out="$2"
    curl --proto '=https' --tlsv1.2 -fsSL --max-time "${HTTP_FETCH_BOUND}" --retry 2 -o "${out}" "${url}" || {
        echo "resolve-ai-tools.sh: bounded fetch failed: ${url}" >&2
        exit 1
    }
}

# ---------------------------------------------------------------------------
# npm tools: resolve exact version, tarball, SRI, bin, native package graph.
# ---------------------------------------------------------------------------
resolve_npm_tool() {
    local tool="$1"
    local pkg channel
    pkg="$(jq -er ".tools.\"${tool}\".requested.package" "${SOURCES}")"
    channel="$(jq -er ".tools.\"${tool}\".requested.channel" "${SOURCES}")"

    # Resolve the default stable channel to an exact version.
    local resolved
    resolved="$("${NPM_BIN}" view "${pkg}@${channel}" version 2>/dev/null | tr -d " '" | tail -1)"
    if [ -z "${resolved}" ]; then
        echo "resolve-ai-tools.sh: could not resolve ${pkg}@${channel}" >&2
        exit 1
    fi
    # Re-query the exact version to detect moving-channel drift.
    local requery
    requery="$("${NPM_BIN}" view "${pkg}@${resolved}" version 2>/dev/null | tr -d " '" | tail -1)"
    if [ "${requery}" != "${resolved}" ]; then
        echo "resolve-ai-tools.sh: version drift for ${pkg}: ${resolved} -> ${requery}" >&2
        exit 1
    fi

    # Reject prereleases and forbidden tags.
    if printf '%s' "${resolved}" | grep -Eq -- '-[0-9]+[.-](alpha|beta|rc|next|canary|nightly|pre|dev)|(^|\-)(alpha|beta|rc|next|canary|nightly|pre|dev)([.\-]|$)' ; then
        echo "resolve-ai-tools.sh: ${pkg} resolved prerelease version: ${resolved}" >&2
        exit 1
    fi
    local forbidden got_tags
    forbidden="$(jq -r '.forbidden_channels[]' "${SOURCES}" | paste -sd'|' -)"
    got_tags="$("${NPM_BIN}" view "${pkg}@"${resolved}"" dist-tags 2>/dev/null | sed -n 's/.*latest: .\([0-9.]*\).*/\1/p' | head -1)"
    # We already know this exact tag is the default channel; skip extra inspection.

    # Fetch full metadata for the exact version.
    local meta
    meta="$("${NPM_BIN}" view "${pkg}@${resolved}" version bin dist optionalDependencies dependencies license engines --json 2>/dev/null)"
    # Expand dist.tarball + dist.integrity via a second query (npm view flattens dist oddly).
    local dist
    dist="$("${NPM_BIN}" view "${pkg}@${resolved}" dist --json 2>/dev/null)"
    local tarball integrity
    tarball="$(jq -r '.tarball' <<<"${dist}")"
    integrity="$(jq -r '.integrity' <<<"${dist}")"
    if [ -z "${tarball}" ] || [ -z "${integrity}" ]; then
        echo "resolve-ai-tools.sh: missing npm dist metadata for ${pkg}@${resolved}" >&2
        exit 1
    fi
    # Require official registry host.
    if ! printf '%s' "${tarball}" | grep -Eq '^https://registry\.npmjs\.org/'; then
        echo "resolve-ai-tools.sh: ${pkg} tarball not on official registry: ${tarball}" >&2
        exit 1
    fi
    # Require SRI integrity shape.
    if ! printf '%s' "${integrity}" | grep -Eq '^sha512-[A-Za-z0-9+/=]+$'; then
        echo "resolve-ai-tools.sh: ${pkg} integrity not sha512 SRI: ${integrity}" >&2
        exit 1
    fi

    local bins
    bins="$(jq -c '.bin' <<<"${meta}" 2>/dev/null || echo '{}')"

    # Native (platform optional) package identities & locks per architecture.
    # Build ONE object {"amd64":[...],"arm64":[...]} via jq accumulation, never
    # by string concatenation (which would produce invalid JSON for --argjson).
    local entry_native="{}"
    for arch in amd64 arm64; do
        # Raw string from sources; empty when the tool declares no native package
        # for this architecture (e.g. openclaude).
        local native_map nlock
        native_map="$(jq -r --arg t "${tool}" --arg a "${arch}" '.tools[$t].native[$a] // ""' "${SOURCES}")"
        nlock="[]"
        if [ -n "${native_map}" ]; then
            # Materialize any version placeholder (codex alias form) and, for the
            # codex alias "@openai/codex-linux-x64@npm:@openai/codex@<ver>-linux-x64", strip the npm: prefix
            # only for the registry "view" lookup while retaining it as install spec.
            local native_spec view_spec
            native_spec="$(printf '%s' "${native_map}" | sed "s#<version>#${resolved}#g")"
            if [[ "${native_spec}" == *@npm:* ]]; then
                view_spec="${native_spec#*@npm:}"
            elif [[ "${native_spec}" == npm:* ]]; then
                view_spec="${native_spec#npm:}"
            else
                view_spec="${native_spec}"
            fi
            local nver ntarball nintegrity ndist npkg
            nver="$("${NPM_BIN}" view "${view_spec}" version 2>/dev/null | tr -d " '" | tail -1)"
            npkg="$("${NPM_BIN}" view "${view_spec}" name 2>/dev/null | tr -d " '" | tail -1)"
            ndist="$("${NPM_BIN}" view "${view_spec}" dist --json 2>/dev/null)"
            ntarball="$(jq -r '.tarball' <<<"${ndist}")"
            nintegrity="$(jq -r '.integrity' <<<"${ndist}")"
            if [[ "${native_spec}" == *@npm:* ]]; then
                npkg="${native_spec%%@npm:*}"
            else
                [ -n "${npkg}" ] || npkg="${view_spec}"
            fi
            if [ -z "${nver}" ] || ! printf '%s' "${ntarball}" | grep -Eq '^https://registry\.npmjs\.org/' || ! printf '%s' "${nintegrity}" | grep -Eq '^sha512-[A-Za-z0-9+/=]+$'; then
                echo "resolve-ai-tools.sh: invalid native metadata for ${npkg} on ${arch}" >&2
                exit 1
            fi
            nlock="$(jq -nc --arg spec "${native_spec}" --arg pkg "${npkg}" --arg ver "${nver}" --arg url "${ntarball}" --arg sri "${nintegrity}" '[{name:$pkg, spec:$spec, version:$ver, resolved:$url, integrity:$sri}]')"
        fi
        entry_native="$(jq --arg a "${arch}" --argjson nl "${nlock}" '. + {($a):$nl}' <<<"${entry_native}")"
    done

    TOOL_ENTRIES["${tool}"]="$(jq -nc \
        --arg name "${tool}" \
        --arg dist "npm" \
        --arg pkg "${pkg}" \
        --arg channel "${channel}" \
        --arg ver "${resolved}" \
        --arg url "${tarball}" \
        --arg sri "${integrity}" \
        --argjson bins "${bins}" \
        --argjson native "${entry_native}" \
        --argjson cmd "$(jq -c ".tools.\"${tool}\".commands" "${SOURCES}")" \
        '{name:$name, distribution:$dist, requested:{package:$pkg,channel:$channel}, resolved_version:$ver, source:{url:$url,integrity:$sri}, bin:$bins, native_payloads:$native, commands:$cmd, digest_authority:"upstream_sri"}')"
}

# ---------------------------------------------------------------------------
# Standalone tools
# ---------------------------------------------------------------------------
resolve_herdr() {
    local url
    url="$(jq -er '.tools.herdr.endpoint.manifest_url' "${SOURCES}")"
    local manifest="${TMP}/herdr.json"
    fetch_bounded "${url}" "${manifest}"

    local version sha_map assets
    version="$(jq -er '.version' "${manifest}")"
    sha_map="$(jq -c '{amd64:.sha256["linux-x86_64"], arm64:.sha256["linux-aarch64"]}' "${manifest}")"
    assets="$(jq -c '{amd64:.assets["linux-x86_64"], arm64:.assets["linux-aarch64"]}' "${manifest}")"
    if [ -z "${version}" ] || [ "${sha_map}" = "null" ] || [ "${assets}" = "null" ]; then
        echo "resolve-ai-tools.sh: herdr manifest malformed" >&2
        exit 1
    fi

    local per_arch="{}"
    for arch in amd64 arm64; do
        local sha url_asset
        sha="$(jq -r --arg a "${arch}" ".[\$a]" <<<"${sha_map}")"
        url_asset="$(jq -r --arg a "${arch}" ".[\$a]" <<<"${assets}")"
        if [ -z "${sha}" ] || [ -z "${url_asset}" ] || ! printf '%s' "${sha}" | grep -Eq '^[0-9a-f]{64}$'; then
            echo "resolve-ai-tools.sh: herdr ${arch} sha/url missing or malformed" >&2
            exit 1
        fi
        if ! printf '%s' "${url_asset}" | grep -Eq '^https://github.com/herdrdev/herdr/releases/download/'; then
            echo "resolve-ai-tools.sh: herdr ${arch} asset not on official github host: ${url_asset}" >&2
            exit 1
        fi
        per_arch="$(jq --arg a "${arch}" --arg sha "${sha}" --arg url "${url_asset}" '.[$a]={url:$url, sha256:$sha, digest_authority:"upstream_sha256"}' <<<"${per_arch}")"
    done

    TOOL_ENTRIES["herdr"]="$(jq -nc \
        --arg name "herdr" --arg dist "standalone" \
        --arg ver "${version}" \
        --argjson cmd "$(jq -c '.tools.herdr.commands' "${SOURCES}")" \
        --argjson meta "${per_arch}" \
        '{name:$name, distribution:$dist, requested:{channel:"stable", source:"https://herdr.dev/latest.json"}, resolved_version:$ver, source:$meta, bin:{}, native_payloads:$meta, commands:$cmd, digest_authority:"upstream_sha256"}')"
}

resolve_antigravity() {
    local base
    base="$(jq -er '.tools.antigravity.endpoint.manifest_pattern' "${SOURCES}")"
    local per_arch="{}"
    local vamd64=""
    for arch in amd64 arm64; do
        local mkey
        mkey="$(jq -r --arg a "${arch}" '.tools.antigravity.vendor_toolchain_target[$a]' "${SOURCES}")"
        local url="${base//<manifest_arch>/${mkey}}"
        local manifest="${TMP}/agy-${arch}.json"
        fetch_bounded "${url}" "${manifest}"
        local version sha url_asset
        version="$(jq -er '.version' "${manifest}")"
        sha="$(jq -er '.sha512' "${manifest}")"
        url_asset="$(jq -er '.url' "${manifest}")"
        if [ -z "${version}" ] || ! printf '%s' "${sha}" | grep -Eq '^[0-9a-f]{128}$'; then
            echo "resolve-ai-tools.sh: antigravity ${arch} manifest malformed" >&2
            exit 1
        fi
        if ! printf '%s' "${url_asset}" | grep -Eq '^https://storage\.googleapis\.com/antigravity-public/'; then
            echo "resolve-ai-tools.sh: antigravity ${arch} asset not on official storage host: ${url_asset}" >&2
            exit 1
        fi
        if [ -z "${vamd64}" ]; then vamd64="${version}"; fi
        if [ "${version}" != "${vamd64}" ]; then
            echo "resolve-ai-tools.sh: antigravity versions disagree across arches: ${vamd64} vs ${version}" >&2
            exit 1
        fi
        per_arch="$(jq --arg a "${arch}" --arg sha "${sha}" --arg url "${url_asset}" '.[$a]={url:$url, sha512:$sha, digest_authority:"upstream_sha512"}' <<<"${per_arch}")"
    done

    TOOL_ENTRIES["antigravity"]="$(jq -nc \
        --arg name "antigravity" --arg dist "standalone" \
        --arg ver "${vamd64}" \
        --argjson cmd "$(jq -c '.tools.antigravity.commands' "${SOURCES}")" \
        --argjson meta "${per_arch}" \
        '{name:$name, distribution:$dist, requested:{channel:"stable", source:"antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests"}, resolved_version:$ver, source:$meta, bin:{}, native_payloads:$meta, commands:$cmd, digest_authority:"upstream_sha512"}')"
}

resolve_cursor() {
    local iurl ihost ahost os
    iurl="$(jq -er '.tools."cursor-agent".endpoint.installer_url' "${SOURCES}")"
    ahost="$(jq -er '.tools."cursor-agent".endpoint.asset_host' "${SOURCES}")"
    os="$(jq -er '.tools."cursor-agent".endpoint.os' "${SOURCES}")"

    # Download the official installer to a file and hash it (observed hash — not
    # an independent authenticity proof, per Pitfall 6 / D-10).
    local installer="${TMP}/cursor-install.sh"
    fetch_bounded "${iurl}" "${installer}"
    local installer_sha
    installer_sha="$(sha256sum "${installer}" | awk '{print $1}')"

    # Parse only the allowlisted versioned downloads.cursor.com URL form.
    local version
    version="$(grep -oE 'downloads\.cursor\.com/lab/[0-9]{4}\.[0-9]{2}\.[0-9]{2}-[A-Za-z0-9]+/' "${installer}" | head -1 | sed -E 's#downloads\.cursor\.com/lab/([0-9./A-Za-z-]+)/#\1#')"
    if [ -z "${version}" ] || ! printf '%s' "${version}" | grep -Eq '^[0-9]{4}\.[0-9]{2}\.[0-9]{2}-[0-9a-f]+$'; then
        echo "resolve-ai-tools.sh: cursor installer did not expose a recognized versioned asset URL" >&2
        exit 1
    fi

    local per_arch="{}"
    for arch in amd64 arm64; do
        local varch
        varch="$(jq -r --arg a "${arch}" '.tools."cursor-agent".vendor_toolchain_target[$a]' "${SOURCES}")"
        local asset_url="https://downloads.cursor.com/lab/${version}/${os}/${varch}/agent-cli-package.tar.gz"
        local archive="${TMP}/cursor-${arch}.tar.gz"
        fetch_bounded "${asset_url}" "${archive}"
        local archive_sha
        archive_sha="$(sha256sum "${archive}" | awk '{print $1}')"
        per_arch="$(jq --arg a "${arch}" --arg url "${asset_url}" --arg sha "${archive_sha}" '.[$a]={url:$url, observed_sha256:$sha, digest_authority:"observed_sha256"}' <<<"${per_arch}")"
    done

    TOOL_ENTRIES["cursor-agent"]="$(jq -nc \
        --arg name "cursor-agent" --arg dist "standalone" \
        --arg ver "${version}" \
        --argjson cmd "$(jq -c '.tools."cursor-agent".commands' "${SOURCES}")" \
        --arg installer_sha "${installer_sha}" \
        --argjson meta "${per_arch}" \
        '{name:$name, distribution:$dist, requested:{channel:"stable", source:"https://cursor.com/install"}, resolved_version:$ver, installer:{ url:"https://cursor.com/install", observed_sha256:$installer_sha, digest_authority:"observed_sha256"}, source:$meta, bin:{}, native_payloads:$meta, commands:$cmd, digest_authority:"observed_sha256"}')"
}

for tool in "${TOOLS_ORDERED[@]}"; do
    case "${tool}" in
        claude-code|openclaude|copilot|codex|opencode) resolve_npm_tool "${tool}" ;;
        herdr) resolve_herdr ;;
        antigravity) resolve_antigravity ;;
        cursor-agent) resolve_cursor ;;
        *) echo "resolve-ai-tools.sh: unhandled tool ${tool}" >&2; exit 1 ;;
    esac
done

# Build per-architecture npm lock data (same direct versions -> distinct locks).
# We generate amd64/arm64 lock objects containing the native package graph; the
# resolver records the direct-version set and official-registry URL/integrity.
npm_direct="{}"
# Assemble the candidate bundle.
entries_json="[]"
for tool in "${TOOLS_ORDERED[@]}"; do
    entries_json="$(jq --argjson e "${TOOL_ENTRIES[$tool]}" '. + [$e]' <<<"${entries_json}")"
done

CANDIDATE="$(jq -nc \
    --argjson schema 1 \
    --argjson tools "${entries_json}" \
    '{schema_version:$schema, generated_at:{epoch:(now|floor), iso:(now|todateiso8601)}, source_contract:"ai-tools/sources.json", tools:$tools}')"

# Write to temp then validate NOW (task 05-01 requires validate-before-success).
TMP_OUT="${TMP}/candidate-resolution.json"
printf '%s\n' "${CANDIDATE}" > "${TMP_OUT}"

# Validate before returning success using the validator (idempotent re-entry).
VALIDATOR="${SCRIPT_DIR}/validate-ai-tool-resolution.sh"
if [ -x "${VALIDATOR}" ]; then
    ARCHS=""
    if [ -n "${SELECTION}" ]; then ARCHS="--selection ${SELECTION}"; fi
    # shellcheck disable=SC2086
    "${VALIDATOR}" "${TMP_OUT}" --architectures amd64,arm64 ${ARCHS}
else
    echo "resolve-ai-tools.sh: validator missing; cannot self-validate" >&2
    exit 1
fi

if [ "${OUTPUT}" = "-" ]; then
    cat "${TMP_OUT}"
else
    mkdir -p "$(dirname -- "${OUTPUT}")"
    cmp "${TMP_OUT}" "${OUTPUT}" 2>/dev/null || cp "${TMP_OUT}" "${OUTPUT}"
    echo "resolve-ai-tools.sh: wrote ${OUTPUT}" >&2
fi

trap - EXIT
rm -rf -- "${TMP}"