#!/usr/bin/env bash
# Mandatory, live, blocking npm package-identity / legitimacy gate (D-25).
#
# Runs immediately BEFORE npm installation (Plan 05-04) to independently re-confirm
# each of the five D-04 npm package identities against (a) current official
# vendor documentation/repository text and (b) current official npm registry
# metadata, compared to the already-resolved candidate bundle (never re-resolving).
#
# Fails closed (nonzero) on: package-set drift, missing official-source linkage,
# registry/candidate version drift, tarball-host substitution, integrity drift,
# unexpected bin surface, prerelease selection, or missing platform native
# optional dependencies. Produces no reusable approval override and never modifies
# the candidate bundle.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

SOURCES=""
RESOLUTION=""
MODE="live"

usage() {
    cat >&2 <<'EOF'
usage: verify-npm-package-identities.sh [--sources SOURCES_JSON] [--resolution CANDIDATE_JSON] [--self-test] [--internal-structural FILE]
EOF
    exit 2
}

while (($#)); do
    case "$1" in
        --sources) SOURCES="$2"; shift 2 ;;
        --resolution) RESOLUTION="$2"; shift 2 ;;
        --self-test) MODE="self-test"; shift ;;
        --internal-structural) MODE="internal"; INTERNAL_RES="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "verify-npm-package-identities.sh: unknown option: $1" >&2; usage ;;
    esac
done

[ -n "${SOURCES}" ] || SOURCES="${PROJECT_ROOT}/ai-tools/sources.json"
[ -n "${RESOLUTION}" ] || RESOLUTION="${PROJECT_ROOT}/.build/ai-tools/candidate-resolution.json"
[ -f "${SOURCES}" ] || { echo "verify-npm: sources missing: ${SOURCES}" >&2; exit 1; }

is_codium_shim() {
    local target="$1"
    [ -n "$target" ] && [ -f "$target" ] && grep -q 'codium-shim' "$target" 2>/dev/null
}

if [ -n "${NPM_BIN:-}" ] && [ -x "${NPM_BIN}" ] && ! is_codium_shim "${NPM_BIN}"; then
    : # Keep user-specified NPM_BIN
elif command -v npm-native >/dev/null 2>&1 && ! is_codium_shim "$(command -v npm-native)"; then
    NPM_BIN="$(command -v npm-native)"
elif [ -x /usr/bin/npm ] && ! is_codium_shim /usr/bin/npm; then
    NPM_BIN="/usr/bin/npm"
elif command -v npm >/dev/null 2>&1 && ! is_codium_shim "$(command -v npm)"; then
    NPM_BIN="$(command -v npm)"
else
    echo "verify-npm: no native npm (Phase 4 shim prohibited)" >&2
    exit 1
fi
NPM_BIN_DIR="$(dirname -- "${NPM_BIN}")"
export PATH="${NPM_BIN_DIR}:/usr/local/bin:/usr/bin:/bin"

FETCH_BOUND=45
fail() { local r="$1"; shift; echo "verify-npm-package-identities.sh: FAIL[${r}]: $*" >&2; exit 1; }

NPM_TOOLS="claude-code openclaude copilot codex opencode"

declare -A PKG_OFFICIAL PKG_EXPECT
PKG_OFFICIAL[claude-code]="https://raw.githubusercontent.com/anthropics/claude-code/main/README.md"
PKG_EXPECT[claude-code]="@anthropic-ai/claude-code"
PKG_OFFICIAL[openclaude]="https://raw.githubusercontent.com/Gitlawb/openclaude/main/README.md"
PKG_EXPECT[openclaude]="@gitlawb/openclaude"
PKG_OFFICIAL[copilot]="https://raw.githubusercontent.com/github/copilot-cli/main/README.md"
PKG_EXPECT[copilot]="@github/copilot"
PKG_OFFICIAL[codex]="https://raw.githubusercontent.com/openai/codex/main/README.md"
PKG_EXPECT[codex]="@openai/codex"
PKG_OFFICIAL[opencode]="https://opencode.ai/v2/docs"
PKG_EXPECT[opencode]="@opencode/cli"

# ---------------------------------------------------------------------------
# Pure structural validation of a candidate (no network). Used by both the live
# gate (pre-network) and the self-test fixtures. Returns the first failing rule.
# ---------------------------------------------------------------------------
structural_validate() {
    local res="$1"
    [ -f "${res}" ] || fail I000 "candidate not found: ${res}"
    # Scope strictly to npm-distribution tools; standalone tools are handled by
    # the Phase 5 acquisition/verification plans, not this npm identity gate.
    resolved="$(jq -r '.tools[] | select(.distribution=="npm") | .name' "${res}")"
    for t in ${NPM_TOOLS}; do
        printf '%s\n' "${resolved}" | grep -qx "${t}" || fail I001 "required npm tool missing: ${t}"
    done
    while read -r n; do
        [ -n "${n}" ] || continue
        case " ${NPM_TOOLS} " in
            *" ${n} "*) : ;;
            *) fail I002 "unexpected npm package: ${n}" ;;
        esac
    done <<<"${resolved}"

    # Prerelease, tarball host, SRI shape, bin present, native shapes per tool.
    for t in ${NPM_TOOLS}; do
        local ver url sri bins
        ver="$(jq -r ".tools[] | select(.name==\"${t}\") | .resolved_version" "${res}")"
        url="$(jq -r ".tools[] | select(.name==\"${t}\") | .source.url" "${res}")"
        sri="$(jq -r ".tools[] | select(.name==\"${t}\") | .source.integrity" "${res}")"
        bins="$(jq -c ".tools[] | select(.name==\"${t}\") | .bin" "${res}")"
        if printf '%s' "${ver}" | grep -Eq -- '-[0-9]+[.-](alpha|beta|rc|next|canary|nightly|pre|dev)|(^|\-)(alpha|beta|rc|next|canary|nightly|pre|dev)([.\-]|$)'; then
            fail I019 "prerelease version selected for ${t}: ${ver}"
        fi
        printf '%s' "${url}" | grep -Eq '^https://registry\.npmjs\.org/' || fail I007 "${t} tarball host not official registry: ${url}"
        printf '%s' "${sri}" | grep -Eq '^sha512-[A-Za-z0-9+/=]+$' || fail I009 "${t} SRI malformed: ${sri}"
        jq -e '. != {}' <<<"${bins}" >/dev/null 2>&1 || fail I011 "${t} declares no bin surface"
        for a in amd64 arm64; do
            jq -e --arg a "${a}" ".tools[] | select(.name==\"${t}\") | .native_payloads[\$a] | type==\"array\"" "${res}" >/dev/null 2>&1 || fail I013 "${t} missing ${a} native_payloads array"
        done
    done
    # Per-arch native integrity + host (skip empty lists, e.g. openclaude).
    for t in ${NPM_TOOLS}; do
        for a in amd64 arm64; do
            jq -e --arg t "${t}" --arg a "${a}" "[.tools[] | select(.name==\$t) | .native_payloads[\$a][]] | all(.[]; (.resolved|test(\"^https://registry\\\\.npmjs\\\\.org/\")) and (.integrity|test(\"^sha512-[A-Za-z0-9+/=]+\$\")) and (.version|length>0))" "${res}" >/dev/null 2>&1 || fail I015 "${t} native package invalid on ${a}"
        done
    done
    # No secret-like keys and no user paths.
    if jq -r '.. | objects | (keys[]? // empty)' "${res}" 2>/dev/null | grep -qiE '^(token|secret|api.?key|credential|authorization|env|environment)$'; then
        fail I017 "candidate exposes a secret-like key"
    fi
    if jq -r '.. | strings' "${res}" 2>/dev/null | grep -qE '/(root|config)/'; then
        fail I018 "candidate contains a /root or /config path"
    fi
}

# ---------------------------------------------------------------------------
# Live identity gate: candidate + official-source linkage + registry agreement.
# ---------------------------------------------------------------------------
verify_live() {
    export HOME="$(mktemp -d)"
    export npm_config_cache="${HOME}/.npm"
    structural_validate "${RESOLUTION}"
    echo "=== npm package identity gate (D-25) ==="
    for t in ${NPM_TOOLS}; do
        local pkg channel cand_ver cand_url cand_sri official expect
        pkg="$(jq -r ".tools[] | select(.name==\"${t}\") | .requested.package" "${RESOLUTION}")"
        channel="$(jq -r ".tools[] | select(.name==\"${t}\") | .requested.channel" "${RESOLUTION}")"
        cand_ver="$(jq -r ".tools[] | select(.name==\"${t}\") | .resolved_version" "${RESOLUTION}")"
        cand_url="$(jq -r ".tools[] | select(.name==\"${t}\") | .source.url" "${RESOLUTION}")"
        cand_sri="$(jq -r ".tools[] | select(.name==\"${t}\") | .source.integrity" "${RESOLUTION}")"
        official="${PKG_OFFICIAL[$t]}"; expect="${PKG_EXPECT[$t]}"

        local doc
        for attempt in 1 2 3 4 5; do
            doc="$(curl --proto '=https' --tlsv1.2 -fsSL --max-time "${FETCH_BOUND}" "${official}" 2>/dev/null || echo "")"
            if [ -n "${doc}" ] && grep -F "${expect}" <<< "${doc}" >/dev/null 2>&1; then
                break
            fi
            sleep 1
        done
        [ -n "${doc}" ] || fail I003 "no official-source content for ${pkg} (${official})"
        grep -F "${expect}" <<< "${doc}" >/dev/null 2>&1 || fail I003 "official source no longer names '${expect}' for ${t} (${official})"

        # Current channel version; reject prerelease.
        local cur_ver
        cur_ver="$("${NPM_BIN}" view "${pkg}@${channel}" version 2>/dev/null | tr -d " '" | tail -1)"
        [ -n "${cur_ver}" ] || fail I004 "cannot read current registry version for ${pkg}@${channel}"
        if printf '%s' "${cur_ver}" | grep -Eq -- '-[0-9]+[.-](alpha|beta|rc|next|canary|nightly|pre|dev)|(^|\-)(alpha|beta|rc|next|canary|nightly|pre|dev)([.\-]|$)'; then
            fail I019 "current ${pkg}@${channel} is a prerelease: ${cur_ver}"
        fi

        # Candidate version must still resolve on the registry (accept newer stable).
        "${NPM_BIN}" view "${pkg}@${cand_ver}" version >/dev/null 2>&1 || fail I006 "candidate version no longer resolvable: ${pkg}@${cand_ver}"

        # Registry tarball + SRI for the EXACT candidate version must equal candidate.
        local exp_url exp_sri exp_bins
        exp_url="$("${NPM_BIN}" view "${pkg}@${cand_ver}" dist.tarball 2>/dev/null | tail -1 | tr -d ' "')"
        exp_sri="$("${NPM_BIN}" view "${pkg}@${cand_ver}" dist.integrity 2>/dev/null | tail -1 | tr -d ' "')"
        [ "${exp_url}" = "${cand_url}" ] || fail I008 "candidate tarball URL differs from registry: ${cand_url} != ${exp_url}"
        [ "${exp_sri}" = "${cand_sri}" ] || fail I010 "candidate SRI differs from registry for ${pkg}@${cand_ver}"

        # Bin surface + native packages present on registry at locked versions.
        exp_bins="$("${NPM_BIN}" view "${pkg}@${cand_ver}" bin --json 2>/dev/null)"
        [ "$(jq -c . <<<"${exp_bins}")" = "$(jq -c . <<<"$(jq -c ".tools[] | select(.name==\"${t}\") | .bin" "${RESOLUTION}")")" ] || fail I011 "bin surface drift for ${pkg}@${cand_ver}"

        for a in amd64 arm64; do
            while IFS= read -r spec; do
                [ -n "${spec}" ] || continue
                local view_spec="${spec}"
                if [[ "${spec}" == *@npm:* ]]; then
                    view_spec="${spec#*@npm:}"
                fi
                "${NPM_BIN}" view "${view_spec}" version >/dev/null 2>&1 || fail I016 "${pkg} native spec no longer resolvable on ${a}: ${spec}"
            done <<<"$(jq -r --arg a "${a}" ".tools[] | select(.name==\"${t}\") | .native_payloads.${a}[].spec" "${RESOLUTION}")"
        done

        printf '  [ok] %-14s %-30s %s\n' "${t}" "${pkg}@${cand_ver}" "${official}"
    done
    echo "verify-npm-package-identities.sh: all five npm identities confirmed (no reusable approval override produced)." >&2
    exit 0
}

# ---------------------------------------------------------------------------
# --self-test: derive negative fixtures from the validated candidate and assert
# each specific rule rejects the mutation using the same structural validator.
# Never a substitute for the mandatory live gate.
# ---------------------------------------------------------------------------
self_test() {
    local base="${RESOLUTION}" st_total=0 st_pass=0
    local st_dir; st_dir="$(mktemp -d)"

    run_neg() {
        local name="$1" rule="$2" resfile="$3"
        st_total=$((st_total+1))
        local out
        # shellcheck disable=SC2086
        if out="$(scripts/verify-npm-package-identities.sh --internal-structural "${resfile}" 2>&1)"; then
            echo "  [FAIL] ${name}: fixture unexpectedly passed"
        elif printf '%s\n' "${out}" | grep -Fq "FAIL[${rule}]"; then
            echo "  [ok] ${name}: rejected via ${rule}"
            st_pass=$((st_pass+1))
        else
            echo "  [FAIL] ${name}: rejected but not by ${rule}: $(printf '%s' "${out}" | tail -1)"
        fi
    }

    jq 'del(.tools[] | select(.name=="opencode"))' "${base}" > "${st_dir}/remove.json"
    run_neg "remove-package" "I001" "${st_dir}/remove.json"

    jq '.tools += [{name:"evil-pkg", distribution:"npm", requested:{package:"@evil/evil",channel:"latest"}, resolved_version:"1.0.0", source:{url:"https://registry.npmjs.org/@evil/evil/-/evil-1.0.0.tgz",integrity:"sha512-AAAA"}, bin:{evil:"bin/x"}, native_payloads:{amd64:[],arm64:[]}, commands:["evil"], digest_authority:"upstream_sri"}]' "${base}" > "${st_dir}/add.json"
    run_neg "add-package" "I002" "${st_dir}/add.json"

    jq '.tools |= map(if .name=="codex" then .resolved_version="0.158.0-beta.1" else . end)' "${base}" > "${st_dir}/pre.json"
    run_neg "prerelease" "I019" "${st_dir}/pre.json"

    jq '.tools |= map(if .name=="claude-code" then .source.url="https://evil.example/x.tgz" else . end)' "${base}" > "${st_dir}/host.json"
    run_neg "tarball-host" "I007" "${st_dir}/host.json"

    jq '.tools |= map(if .name=="copilot" then .source.integrity="md5-abc" else . end)' "${base}" > "${st_dir}/sri.json"
    run_neg "bad-integrity" "I009" "${st_dir}/sri.json"

    jq '.tools |= map(if .name=="openclaude" then .bin={} else . end)' "${base}" > "${st_dir}/bin.json"
    run_neg "empty-bin" "I011" "${st_dir}/bin.json"

    jq '.tools |= map(if .name=="claude-code" then .native_payloads.amd64 += [.native_payloads.amd64[0] | .integrity="md5-zz"] else . end)' "${base}" > "${st_dir}/nativesri.json"
    run_neg "native-integrity" "I015" "${st_dir}/nativesri.json"

    jq '.tools |= map(if .name=="openclaude" then . + {api_key:"nope"} else . end)' "${base}" > "${st_dir}/secret.json"
    run_neg "secret-key" "I017" "${st_dir}/secret.json"

    rm -rf -- "${st_dir}"
    echo "verify-npm self-test: ${st_pass}/${st_total} negative fixtures rejected" >&2
    [ "${st_pass}" -eq "${st_total}" ] || exit 1
    echo "verify-npm self-test: PASS" >&2
    exit 0
}

case "${MODE}" in
    live) verify_live ;;
    internal) structural_validate "${INTERNAL_RES:-${RESOLUTION}}" ; echo "verify-npm structural OK" >&2; exit 0 ;;
    self-test) self_test ;;
esac