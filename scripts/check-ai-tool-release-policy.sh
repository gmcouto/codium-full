#!/usr/bin/env bash
# Fail-closed AI tool redistribution policy checker (D-24).
#
# Modes:
#   --mode local-technical   Passes when the resolved eight-tool set is complete,
#                            evidence is fresh, and every policy record is known.
#                            Explicitly states that technical installability does
#                            NOT grant redistribution approval. Exits 0.
#   --mode external-release  Exits nonzero unless every blocked/unresolved/
#                            conditional tool has an affirmative, independently
#                            supplied approval record that is fresh, tool-exact,
#                            and not repository-self-authored / wildcard / env-only.
#                            With the current policy (all approvals null) it fails
#                            closed and names each blocking tool and rule.
#   --mode report [--output FILE]
#                            Emits a machine-readable JSON report consumed by Phase
#                            7: {external_release_eligible, blockers:[{tool,status,
#                            rule,source}], tools:[...]}. Does NOT modify the
#                            candidate resolution or tool set.
#
# Every expected failure carries a stable RULE identifier (R001..R009).
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
POLICY="${PROJECT_ROOT}/ai-tools/release-policy.json"
if [ ! -f "${POLICY}" ] && [ -f "/opt/codium-ai/release-policy.json" ]; then
    POLICY="/opt/codium-ai/release-policy.json"
fi
NOTICES="${PROJECT_ROOT}/rootfs/usr/local/share/codium-full/licenses/AI-TOOLS-NOTICES.json"
if [ ! -f "${NOTICES}" ]; then
    if [ -f "/usr/local/share/codium-full/licenses/AI-TOOLS-NOTICES.json" ]; then
        NOTICES="/usr/local/share/codium-full/licenses/AI-TOOLS-NOTICES.json"
    elif [ -f "/opt/codium-ai/licenses/AI-TOOLS-NOTICES.json" ]; then
        NOTICES="/opt/codium-ai/licenses/AI-TOOLS-NOTICES.json"
    fi
fi

MODE=""
RESOLUTION=""
OUTPUT=""
SELF_TEST=0
POLICY_OVERRIDE=""

usage() {
    cat >&2 <<'EOF'
usage: check-ai-tool-release-policy.sh --mode local-technical|external-release|report \
       [--resolution CANDIDATE_JSON] [--output REPORT_JSON] [--policy POLICY_JSON] [--self-test]
EOF
    exit 2
}

while (($#)); do
    case "$1" in
        --mode) MODE="$2"; shift 2 ;;
        --resolution) RESOLUTION="$2"; shift 2 ;;
        --output) OUTPUT="$2"; shift 2 ;;
        --policy) POLICY_OVERRIDE="$2"; shift 2 ;;
        --self-test) SELF_TEST=1; shift ;;
        -h|--help) usage ;;
        *) echo "check-ai-tool-release-policy.sh: unknown option: $1" >&2; usage ;;
    esac
done

case "${MODE}" in
    local-technical|external-release|report) : ;;
    "")
        if [ "${SELF_TEST}" -eq 1 ]; then
            MODE="report"
        else
            echo "check-ai-tool-release-policy.sh: --mode required" >&2; usage
        fi
        ;;
    *) echo "check-ai-tool-release-policy.sh: unknown mode: ${MODE}" >&2; usage ;;
esac

[ -f "${POLICY_OVERRIDE:-}" ] && POLICY="${POLICY_OVERRIDE}"
[ -f "${POLICY}" ] || { echo "check: policy missing: ${POLICY}" >&2; exit 1; }
[ -f "${NOTICES}" ] || { echo "check: notices manifest missing: ${NOTICES}" >&2; exit 1; }

if [ -n "${RESOLUTION}" ]; then
    [ -f "${RESOLUTION}" ] || { echo "check: resolution missing: ${RESOLUTION}" >&2; exit 1; }
else
    RESOLUTION="${PROJECT_ROOT}/.build/ai-tools/candidate-resolution.json"
fi

# Canonical nine-tool logical set (must agree between policy, resolution, notices).
ALL_TOOLS="claude-code openclaude copilot codex opencode cursor-agent antigravity herdr pi-agent"

self_test() {
    # Executable negative fixtures (D-28). Each fixture must be rejected with a
    # specific policy rule identifier. Runs the checker on copies under a temp
    # policy so the committed policy is never modified.
    local base_pol="${POLICY}" st_total=0 st_pass=0
    local st_dir; st_dir="$(mktemp -d)"
    local pol2="${st_dir}/policy.json"

    run_pol_neg() {
        local name="$1" expected_rule="$2" polfile="$3"
        st_total=$((st_total+1))
        local out
        # shellcheck disable=SC2086
        if out="$(scripts/check-ai-tool-release-policy.sh --mode external-release --resolution ${RESOLUTION} --policy "${polfile}" 2>&1)"; then
            echo "  [FAIL] policy-${name}: unexpectedly passed"
        elif printf '%s\n' "${out}" | grep -Fq "R${expected_rule}"; then
            echo "  [ok] policy-${name}: rejected via R${expected_rule}"
            st_pass=$((st_pass+1))
        else
            echo "  [FAIL] policy-${name}: rejected but not by R${expected_rule}"
        fi
    }

    # 1. Missing policy entry (remove herdr record) -> R003.
    jq 'del(.tools.herdr)' "${base_pol}" > "${pol2}"
    run_pol_neg "missing-entry" "003" "${pol2}"

    # 2. Unknown status -> R004.
    jq '.tools["claude-code"].status = "bogus"' "${base_pol}" > "${pol2}"
    run_pol_neg "unknown-status" "004" "${pol2}"

    # 3. Stale terms evidence (past expiry) -> R006.
    jq '.tools.codex.expiry = "2000-01-01"' "${base_pol}" > "${pol2}"
    run_pol_neg "stale-evidence" "006" "${pol2}"

    # 4. Resolution/policy tool-set mismatch -> R002.
    st_total=$((st_total+1))
    local stripres; stripres="${st_dir}/res-7.json"
    jq 'del(.tools[] | select(.name=="herdr"))' "${RESOLUTION}" > "${stripres}"
    local out2
    if out2="$(scripts/check-ai-tool-release-policy.sh --mode external-release --resolution "${stripres}" --policy "${base_pol}" 2>&1)"; then
        echo "  [FAIL] toolset-mismatch: unexpectedly passed"
    elif printf '%s\n' "${out2}" | grep -Fq "R002"; then
        echo "  [ok] toolset-mismatch: rejected via R002"
        st_pass=$((st_pass+1))
    else
        echo "  [FAIL] toolset-mismatch: rejected but not by R002"
    fi

    # Pre-condition for approval fixtures: give every restricted tool a VALID
    # approval so that a single mutation is the ONLY failing condition (this is
    # how each specific rule is isolated instead of masking behind R100-MISSING).
make_valid_approvals() {
        local acc
        acc="$(cat "${base_pol}")"
        for t in openclaude cursor-agent antigravity claude-code copilot; do
            acc="$(jq --arg t "${t}" '.tools[$t].external_approval = {issuer:"Independent Legal Counsel", grant:"explicit", date:"2026-09-28", expiry:"2030-01-01", source_url:"https://legal-example.example/grants"}' <<<"${acc}")"
        done
        printf '%s\n' "${acc}" > "${pol2}"
    }

    # 5. Forged/self-authored approval (issuer == repo) -> R102.
    make_valid_approvals
    jq '.tools["claude-code"].external_approval.issuer = "codium-full"' "${pol2}" > "${pol2}.tmp" && mv "${pol2}.tmp" "${pol2}"
    run_pol_neg "self-authored" "102" "${pol2}"

    # 6. Wildcard grant -> R101.
    make_valid_approvals
    jq '.tools["cursor-agent"].external_approval.grant = "wildcard"' "${pol2}" > "${pol2}.tmp" && mv "${pol2}.tmp" "${pol2}"
    run_pol_neg "wildcard" "101" "${pol2}"

    # 7. Stale approval (past expiry) -> R103.
    make_valid_approvals
    jq '.tools.openclaude.external_approval.expiry = "2000-01-01"' "${pol2}" > "${pol2}.tmp" && mv "${pol2}.tmp" "${pol2}"
    run_pol_neg "stale-approval" "103" "${pol2}"

    rm -rf -- "${st_dir}"
    echo "policy-self-test: ${st_pass}/${st_total} negative fixtures rejected" >&2
    [ "${st_pass}" -eq "${st_total}" ] || exit 1
    echo "policy-self-test: PASS" >&2
    exit 0
}

if [ "${SELF_TEST}" -eq 1 ]; then
    self_test
fi

fail_closed() {
    local rule="$1"; shift
    echo "check-ai-tool-release-policy.sh: FAIL[${rule}]: $*" >&2
    exit 1
}

# ----------------------------------------------------------------------------
# Collect the resolved tool set.
# ----------------------------------------------------------------------------
cli_tool_names() { jq -r '.tools[].name' "${RESOLUTION}" 2>/dev/null || echo ""; }
RESOLVED_NAMES="$(cli_tool_names)"

if [ -z "${RESOLVED_NAMES}" ]; then
    fail_closed R001 "cannot read tool set from resolution: ${RESOLUTION}"
fi

# Resolution tool-set must exactly equal the canonical eight-tool set.
expected=""
got=$(printf '%s\n' "${RESOLVED_NAMES}" | sort | tr '\n' ' ' | sed 's/ $//'; echo)
if [ "${got}" != "$(printf '%s' "${ALL_TOOLS}" | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//'; echo)" ]; then
    fail_closed R002 "resolution/policy tool-set mismatch; resolved: ${got}"
fi

# Policy entries must exist and be known for every tool, with a known status.
KNOWN_STATUS='blocked|unresolved|conditional|approved-with-obligations'
for t in ${ALL_TOOLS}; do
    status="$(jq -r --arg t "${t}" '.tools[$t].status // ""' "${POLICY}")"
    [ -n "${status}" ] || fail_closed R003 "missing policy entry for: ${t}"
    printf '%s' "${status}" | grep -Eq "^(${KNOWN_STATUS})$" || fail_closed R004 "unknown policy status '${status}' for: ${t}"
done

# Evidence freshness: every policy record must carry a non-expired expiry/date.
TODAY="$(date -u +%Y-%m-%d)"
for t in ${ALL_TOOLS}; do
    expiry="$(jq -r --arg t "${t}" '.tools[$t].expiry // ""' "${POLICY}")"
    [ -n "${expiry}" ] || fail_closed R005 "missing evidence expiry for: ${t}"
    if [ "$(printf '%s\n%s' "${TODAY}" "${expiry}" | sort | head -1)" = "${expiry}" ]; then
        # expiry <= today means stale/expired.
        fail_closed R006 "stale terms evidence for: ${t} (expired ${expiry})"
    fi
done

# Notices manifest must contain exactly the nine tools with a non-empty disposition.
N_TOOLS="$(jq -r '.tools | length' "${NOTICES}")"
[ "${N_TOOLS}" = "9" ] || fail_closed R007 "notices manifest missing tools (found ${N_TOOLS})"
for t in ${ALL_TOOLS}; do
    disp="$(jq -r --arg t "${t}" '.tools[] | select(.name==$t) | .disposition // ""' "${NOTICES}")"
    [ -n "${disp}" ] || fail_closed R008 "notice record missing disposition for: ${t}"
done

# ----------------------------------------------------------------------------
# Approval-record evaluation (used by external-release and report modes).
# In local-technical mode approvals are irrelevant.
# ----------------------------------------------------------------------------
evaluate_approvals() {
    APPROVAL_BLOCKERS="[]"
    APPROVAL_ALL_OK=1
    for t in ${ALL_TOOLS}; do
        status="$(jq -r --arg t "${t}" '.tools[$t].status' "${POLICY}")"
        # Only blocked / unresolved / conditional require an external approval record.
        case "${status}" in
            blocked|unresolved|conditional) : ;;
            approved-with-obligations) continue ;;
        esac
        appr="$(jq -r --arg t "${t}" '.tools[$t].external_approval // empty' "${POLICY}")"
        if [ -z "${appr}" ] || [ "${appr}" = "null" ]; then
            APPROVAL_BLOCKERS="$(jq --arg t "${t}" --arg s "${status}" --arg r "R100-MISSING_APPROVAL" '. + [{tool:$t,status:$s,rule:$r}]' <<<"${APPROVAL_BLOCKERS}")"
            APPROVAL_ALL_OK=0
            continue
        fi
        # The approval must be a fresh, non-repository-self-authored, non-env grant.
        issuer="$(jq -r --arg t "${t}" '.tools[$t].external_approval.issuer // ""' "${POLICY}")"
        issued="$(jq -r --arg t "${t}" '.tools[$t].external_approval.date // ""' "${POLICY}")"
        expires="$(jq -r --arg t "${t}" '.tools[$t].external_approval.expiry // ""' "${POLICY}")"
        grant="$(jq -r --arg t "${t}" '.tools[$t].external_approval.grant // "wildcard"' "${POLICY}")"
        ref_url="$(jq -r --arg t "${t}" '.tools[$t].external_approval.source_url // ""' "${POLICY}")"

        # Wildcard / empty / env-only approvals rejected.
        if [ "${grant}" = "wildcard" ] || [ -z "${grant}" ] || [ "${grant}" = "\${*}" ] || [[ "${grant}" == *'$'* ]]; then
            APPROVAL_BLOCKERS="$(jq --arg t "${t}" --arg s "${status}" --arg r "R101-WILDCARD" '. + [{tool:$t,status:$s,rule:$r}]' <<<"${APPROVAL_BLOCKERS}")"
            APPROVAL_ALL_OK=0; continue
        fi
        # Self-authored: issuer must NOT be the project itself / repository.
        if [ -z "${issuer}" ] || [[ "${issuer}" =~ ^(self|repo|repository|project|codium|gmcouto)$ ]] || [[ "${issuer}" == *codium* ]]; then
            APPROVAL_BLOCKERS="$(jq --arg t "${t}" --arg s "${status}" --arg r "R102-SELF_AUTHORED" '. + [{tool:$t,status:$s,rule:$r}]' <<<"${APPROVAL_BLOCKERS}")"
            APPROVAL_ALL_OK=0; continue
        fi
        # Freshness.
        if [ -z "${expires}" ] || [ "$(printf '%s\n%s' "${TODAY}" "${expires}" | sort | head -1)" = "${expires}" ]; then
            APPROVAL_BLOCKERS="$(jq --arg t "${t}" --arg s "${status}" --arg r "R103-STALE_APPROVAL" '. + [{tool:$t,status:$s,rule:$r}]' <<<"${APPROVAL_BLOCKERS}")"
            APPROVAL_ALL_OK=0; continue
        fi
        # Source URL required and https.
        if [ -z "${ref_url}" ] || [[ "${ref_url}" != https://* ]]; then
            APPROVAL_BLOCKERS="$(jq --arg t "${t}" --arg s "${status}" --arg r "R104-SOURCE_URL" '. + [{tool:$t,status:$s,rule:$r}]' <<<"${APPROVAL_BLOCKERS}")"
            APPROVAL_ALL_OK=0; continue
        fi
    done
}

evaluate_approvals

# ----------------------------------------------------------------------------
# Mode dispatch
# ----------------------------------------------------------------------------
case "${MODE}" in
    local-technical)
        echo "check-ai-tool-release-policy.sh: local-technical OK: all eight tools resolved, evidence fresh." >&2
        echo "check-ai-tool-release-policy.sh: NOTE: this confers NO redistribution approval (D-24)." >&2
        exit 0
        ;;
    external-release)
        if [ "${APPROVAL_ALL_OK}" -eq 1 ]; then
            echo "check-ai-tool-release-policy.sh: external-release OK: every restricted tool has an affirmative, fresh, independently-sourced approval record." >&2
            exit 0
        fi
        echo "check-ai-tool-release-policy.sh: external-release BLOCKED (policy is fail-closed by design). ${APPROVAL_BLOCKERS}" >&2
        exit 1
        ;;
    report)
        JSON_BLOCKERS="${APPROVAL_BLOCKERS}"
        if [ "${APPROVAL_ALL_OK}" -eq 1 ]; then
            eligible="true"
        else
            eligible="false"
        fi
        report="$(printf '%s\n' ${ALL_TOOLS} | jq -R -s 'split("\n")[:9]' )"
        report="$(jq -nc --argjson blockers "${APPROVAL_BLOCKERS}" --argjson tools "${report}" '{external_release_eligible:('"${eligible}"'=="true"), blockers:$blockers, tools:$tools}')"
        if [ -n "${OUTPUT}" ]; then
            printf '%s\n' "${report}" > "${OUTPUT}"
            echo "check-ai-tool-release-policy.sh: report written to ${OUTPUT}" >&2
        else
            printf '%s\n' "${report}"
        fi
        echo "check-ai-tool-release-policy.sh: report: external_release_eligible=${eligible}" >&2
        exit 0
        ;;
esac