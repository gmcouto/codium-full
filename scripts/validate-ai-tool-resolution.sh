#!/usr/bin/env bash
# Strict validator for the Phase 5 exact candidate-resolution bundle.
# Enforces schema, host, identity, stable-channel, parity, lock, and digest
# contracts. Exits 0 only when every required tool and architecture is present
# and internally consistent. Rule identifiers are emitted on the first failure.
set -euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCES="${PROJECT_ROOT}/ai-tools/sources.json"

usage() {
    cat >&2 <<'EOF'
usage: validate-ai-tool-resolution.sh CANDIDATE_JSON [--architecture a,b] [--selection x,y,z]
EOF
    exit 2
}

[ $# -ge 1 ] || usage
CANDIDATE="$1"; shift
SELECTION=""
ARCHS="amd64,arm64"
SELF_SCHEMA_TEST=0
while (($#)); do
    case "$1" in
        --architectures) ARCHS="$2"; shift 2 ;;
        --selection) SELECTION="$2"; shift 2 ;;
        --self-schema-test) SELF_SCHEMA_TEST=1; shift ;;
        *) echo "unknown option: $1" >&2; usage ;;
    esac
done

fail() {
    local rule="${1:-VALIDATION}"
    shift
    echo "validate-ai-tool-resolution.sh: FAIL[${rule}]: $*" >&2
    exit 1
}

# --------------------------------------------------------------------------
# Executable negative self-tests (D-28 / task 05-01-03). Each fixture mutates
# a valid candidate and MUST be rejected with a specific rule identifier.
# --self-schema-test does not substitute for the mandatory live validation.
# --------------------------------------------------------------------------
self_schema_test() {
    local base="$1"
    local sst_tmp pass=1
    sst_tmp="$(mktemp -d)"
    local diag
    local cases_total=0 cases_passed=0

    run_neg() {
        local name="$1" expected_rule="$2" fixture="$3"
        cases_total=$((cases_total+1))
        # shellcheck disable=SC2086
        if diag="$(bash "${BASH_SOURCE[0]}" "${fixture}" --architectures amd64,arm64 2>&1)"; then
            echo "  [FAIL] ${name}: unexpectedly passed (expected rule ${expected_rule})"
            pass=1
        elif printf '%s\n' "${diag}" | grep -Fq "FAIL[${expected_rule}]"; then
            echo "  [ok] ${name}: rejected by ${expected_rule}"
            cases_passed=$((cases_passed+1))
        else
            echo "  [FAIL] ${name}: rejected but not by ${expected_rule}: $(printf '%s' "${diag}" | tail -1)"
        fi
    }

    # 1. Malformed JSON (truncated document) -> E002 structural.
    printf '%s' '{"schema_version":1,"tools":' > "${sst_tmp}/malformed.json"
    run_neg "malformed-json" "E002" "${sst_tmp}/malformed.json"

    # 2. Missing one required tool (remove herdr) -> E006.
    jq 'del(.tools[] | select(.name=="herdr"))' "${base}" > "${sst_tmp}/missing-tool.json"
    run_neg "missing-tool" "E006" "${sst_tmp}/missing-tool.json"

    # 3. Duplicate tool (duplicate claude-code entry) -> E005.
    jq '. as $root | ($root.tools | map(select(.name=="claude-code")) | first) as $c | $root + {tools:($root.tools + [$c])}' "${base}" > "${sst_tmp}/dup-tool.json"
    run_neg "duplicate-tool" "E005" "${sst_tmp}/dup-tool.json"

    # 4. Duplicate command across tools -> E009.
    jq '. as $root | ($root.tools | map(select(.name=="openclaude")) | first) as $o | $root + {tools:[$root.tools[] | if .name=="openclaude" then $o + {commands:["claude"]} else . end]}' "${base}" > "${sst_tmp}/dup-cmd.json"
    run_neg "duplicate-command" "E009" "${sst_tmp}/dup-cmd.json"

    # 5. Forbidden / non-stable channel -> E010.
    jq '.tools |= map(if .name=="claude-code" then .requested += {channel:"nightly"} else . end)' "${base}" > "${sst_tmp}/bad-channel.json"
    run_neg "forbidden-channel" "E010" "${sst_tmp}/bad-channel.json"

    # 6. Prerelease resolved version -> E011.
    jq '.tools |= map(if .name=="copilot" then .resolved_version = "1.0.0-beta.1" else . end)' "${base}" > "${sst_tmp}/prerelease.json"
    run_neg "prerelease-version" "E011" "${sst_tmp}/prerelease.json"

    # 7. Missing architecture record -> E012.
    jq '.tools |= map(if .name=="herdr" then del(.native_payloads.arm64) else . end)' "${base}" > "${sst_tmp}/missing-arch.json"
    run_neg "missing-architecture" "E012" "${sst_tmp}/missing-arch.json"

    # 8. npm source on unallowlisted host -> E013.
    jq '.tools |= map(if .name=="codex" then .source.url = "https://evil.example/x.tgz" else . end)' "${base}" > "${sst_tmp}/bad-host.json"
    run_neg "npm-host-substitution" "E013" "${sst_tmp}/bad-host.json"

    # 9. npm integrity not sha512 -> E014.
    jq '.tools |= map(if .name=="claude-code" then .source.integrity = "md5-abc" else . end)' "${base}" > "${sst_tmp}/bad-integrity.json"
    run_neg "npm-integrity" "E014" "${sst_tmp}/bad-integrity.json"

    # 10. Herdr sha256 not 64-hex -> E017.
    jq '.tools |= map(if .name=="herdr" then .native_payloads.amd64.sha256 = "zz" else . end)' "${base}" > "${sst_tmp}/herdr-digest.json"
    run_neg "herdr-digest" "E017" "${sst_tmp}/herdr-digest.json"

    # 11. Antigravity sha512 not 128-hex -> E018.
    jq '.tools |= map(if .name=="antigravity" then .native_payloads.amd64.sha512 = "zz" else . end)' "${base}" > "${sst_tmp}/agy-digest.json"
    run_neg "antigravity-digest" "E018" "${sst_tmp}/agy-digest.json"

    # 12. Cursor observed hash replaced by upstream authority -> E019.
    jq '.tools |= map(if .name=="cursor-agent" then .native_payloads.amd64 += {digest_authority:"upstream_sha256"} else . end)' "${base}" > "${sst_tmp}/cursor-auth.json"
    run_neg "cursor-upstream-claim" "E019" "${sst_tmp}/cursor-auth.json"

    # 13. Secret-like key anywhere -> E021.
    jq '.tools |= map(if .name=="claude-code" then . + {"api_key":"nope"} else . end)' "${base}" > "${sst_tmp}/secret.json"
    run_neg "secret-like-key" "E021" "${sst_tmp}/secret.json"

    rm -rf -- "${sst_tmp}"
    echo "self-schema-test: ${cases_passed}/${cases_total} negative fixtures rejected" >&2
    [ "${cases_passed}" -eq "${cases_total}" ] && [ "${pass}" -eq 1 ] || exit 1
    echo "self-schema-test: PASS" >&2
    exit 0
}

if [ "${SELF_SCHEMA_TEST}" -eq 1 ]; then
    [ -f "${CANDIDATE}" ] || { echo "validate: --self-schema-test requires a valid candidate path" >&2; exit 2; }
    self_schema_test "${CANDIDATE}"
fi

[ -f "${CANDIDATE}" ] || fail E001 "candidate not found: ${CANDIDATE}"
[ -f "${SOURCES}" ] || fail E001B "sources contract missing: ${SOURCES}"

# --------------------------------------------------------------------------
# Structural schema
# --------------------------------------------------------------------------
jq -e 'has("schema_version") and (.schema_version == 1) and has("tools") and (.tools|type=="array")' "${CANDIDATE}" >/dev/null 2>&1 || fail E002 "candidate missing schema_version/tools or schema_version != 1"
[ "$(jq -r '.tools | length' "${CANDIDATE}")" != "0" ] || fail E003 "candidate has no tools"

# Every tool entry must be an object with required typed fields.
jq -e 'all(.tools[]; (type=="object") and has("name") and has("distribution") and has("resolved_version") and has("source") and has("commands") and has("native_payloads"))' "${CANDIDATE}" >/dev/null 2>&1 || fail E004 "an entry is missing required fields"

# --------------------------------------------------------------------------
# Identity: exact required logical set, once each, no duplicates.
# --------------------------------------------------------------------------
TOOL_NAMES="$(jq -r '.tools[].name' "${CANDIDATE}")"
UNIQUE_COUNT="$(jq -r '[.tools[].name] | unique | length' "${CANDIDATE}")"
TOTAL_COUNT="$(jq -r '.tools | length' "${CANDIDATE}")"
[ "${UNIQUE_COUNT}" = "${TOTAL_COUNT}" ] || fail E005 "duplicate logical tool names in candidate"

ALL_TOOLS="claude-code
openclaude
copilot
codex
opencode
cursor-agent
antigravity
herdr"

if [ -n "${SELECTION}" ]; then
    IFS=',' read -r -a REQSEL <<<"${SELECTION}"
else
    REQSEL=( ${ALL_TOOLS} )
fi

for t in "${REQSEL[@]}"; do
    printf '%s\n' "${TOOL_NAMES}" | grep -qx "${t}" || fail E006 "required tool missing: ${t}"
done

# Reject any tool not part of the canonical eight-tool set.
while read -r t; do
    printf '%s\n' "${ALL_TOOLS}" | grep -qx "${t}" || fail E007 "unknown tool present: ${t}"
done <<<"${TOOL_NAMES}"

# --------------------------------------------------------------------------
# Command surface: no duplicate command across tools, each tool has >= 1.
# --------------------------------------------------------------------------
jq -e 'all(.tools[]; (.commands|type=="array") and (length > 0))' "${CANDIDATE}" >/dev/null 2>&1 || fail E008 "a tool lists zero commands"
jq -e '[.tools[].commands[]] | length == (unique | length)' "${CANDIDATE}" >/dev/null 2>&1 || fail E009 "duplicate command across tools"

# --------------------------------------------------------------------------
# Stable-channel identity (no forbidden channels / prereleases).
# --------------------------------------------------------------------------
if jq -e 'all(.tools[]; (.requested.channel == "latest" or .requested.channel == "stable"))' "${CANDIDATE}" >/dev/null 2>&1; then :; else
    fail E010 "a tool declares a forbidden/non-stable channel"
fi

# Prerelease / moving development tag rejection for resolved versions.
if jq -e '[.tools[].resolved_version] | all(.[]; test("(^|[-.])(alpha|beta|rc|next|canary|nightly|pre|dev)([.-]|$)";"i") | not)' "${CANDIDATE}" >/dev/null 2>&1; then :; else
    fail E011 "a resolved version looks like a prerelease"
fi

# --------------------------------------------------------------------------
# Architecture parity: BOTH amd64 and arm64 mandatory for every tool.
# --------------------------------------------------------------------------
IFS=',' read -r -a ARCHLIST <<<"${ARCHS}"
for t in "${REQSEL[@]}"; do
    for a in "${ARCHLIST[@]}"; do
        # npm tools carry native_payloads.<arch>[] (may be empty for openclaude).
        # standalone tools carry native_payloads.<arch>.url.
        present="$(jq -r --arg t "${t}" --arg a "${a}" '.tools[] | select(.name==$t) | .native_payloads[$a] // empty' "${CANDIDATE}")"
        [ -n "${present}" ] || fail E012 "tool ${t} missing architecture record: ${a}"
    done
done

# --------------------------------------------------------------------------
# Host allowlists
# --------------------------------------------------------------------------
REGISTRY_HOST='^https://registry\.npmjs\.org/'
# npm tarball URLs on official registry only. Applies to npm-distributed tools
# (standalone tools carry object-typed 'source' maps validated separately).
jq -e --arg re "${REGISTRY_HOST}" '[.tools[] | select(.distribution=="npm") | .source.url] | all(.[]; (type=="string") and (test($re)))' "${CANDIDATE}" >/dev/null 2>&1 || fail E013 "npm source tarball not on official registry host"

# --------------------------------------------------------------------------
# Lock / integrity: npm tools carry sha512 SRI; standalone carry typed digests.
# --------------------------------------------------------------------------
# For each npm tool entry, the 'source' object holds integrity:sha512-...
jq -e '[.tools[] | select(.distribution=="npm") | .source] | all(.[]; (.integrity|test("^sha512-[A-Za-z0-9+/=]+$")))' "${CANDIDATE}" >/dev/null 2>&1 || fail E014 "npm tool integrity is not valid sha512 SRI"

# Native lattice integrity for each arch (where native_payloads.<arch> is array).
jq -e '[.tools[] | select(.distribution=="npm") | .native_payloads[]? | select(type=="array")[]?] | all(.[]; (.integrity|test("^sha512-[A-Za-z0-9+/=]+$")) and (.resolved|test("^https://registry\\.npmjs\\.org/")))' "${CANDIDATE}" >/dev/null 2>&1 || fail E015 "npm native package lock invalid (host or SRI)"

# Standalone digests: authoritative sha256 (herdr), sha512 (antigravity);
# cursor must be observed_sha256, and NEVER upstream_verified. These rules are
# candidate-aware: only standalone tools actually present in the bundle are
# checked (a --selection run may omit one).
for t in herdr antigravity cursor-agent; do
    # Skip a standalone tool that is not part of the candidate set.
    if ! printf '%s\n' "${TOOL_NAMES}" | grep -qx "${t}"; then continue; fi
    for a in "${ARCHLIST[@]}"; do
        auth="$(jq -r --arg t "${t}" --arg a "${a}" '.tools[] | select(.name==$t) | .native_payloads[$a].digest_authority // empty' "${CANDIDATE}")"
        [ -n "${auth}" ] || fail E016 "tool ${t} missing digest_authority for ${a}"
    done
done
jq -e '[.tools[] | select(.name=="herdr") | .native_payloads[] ] | all(.[]; (.sha256|test("^[0-9a-f]{64}$")) and .digest_authority=="upstream_sha256")' "${CANDIDATE}" >/dev/null 2>&1 || fail E017 "herdr digest malformed"
jq -e '[.tools[] | select(.name=="antigravity") | .native_payloads[] ] | all(.[]; (.sha512|test("^[0-9a-f]{128}$")) and .digest_authority=="upstream_sha512")' "${CANDIDATE}" >/dev/null 2>&1 || fail E018 "antigravity digest malformed"
jq -e '[.tools[] | select(.name=="cursor-agent") | .native_payloads[] ] | all(.[]; (.observed_sha256|test("^[0-9a-f]{64}$")) and .digest_authority=="observed_sha256")' "${CANDIDATE}" >/dev/null 2>&1 || fail E019 "cursor hash must be observed_sha256 (not upstream)"

# --------------------------------------------------------------------------
# Version agreement across architectures (direct npm semantic versions).
# Selection-aware: only npm tools actually present in the candidate are checked,
# and each must carry a resolved_version. Guarded so it never aborts silently
# under `set -e`.
for t in claude-code openclaude copilot codex opencode; do
    if ! printf '%s\n' "${TOOL_NAMES}" | grep -qx "${t}"; then continue; fi
    jq -e --arg t "${t}" '[.tools[] | select(.name==$t and .distribution=="npm") | .resolved_version] | length == 1' "${CANDIDATE}" >/dev/null 2>&1 \
        || fail E020 "npm tool ${t} must resolve to exactly one version"
done

# --------------------------------------------------------------------------
# Reject secret-like / environment-dump / user-path fields anywhere.
# --------------------------------------------------------------------------
if jq -r '.. | objects | (keys[]? // empty)' "${CANDIDATE}" 2>/dev/null | grep -qiE '^(token|secret|api.?key|credential|authorization|env|environment)$' ; then
    fail E021 "candidate exposes a secret-like key"
fi

# Reject /root or /config paths anywhere.
if jq -r '.. | strings' "${CANDIDATE}" 2>/dev/null | grep -qE '/(root|config)/|(^|:)(/root|/config)(:|$)' ; then
    fail E022 "candidate contains a /root or /config path"
fi

echo "validate-ai-tool-resolution.sh: OK (${TOTAL_COUNT} tools, arch=${ARCHS})" >&2
exit 0