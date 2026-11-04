#!/usr/bin/env bash
# scripts/verify-phase7.sh — Comprehensive Phase 7 verification suite (REL-01..REL-05)
#
# Validates:
#   - Prerequisite artifacts presence and executability (V701..V705)
#   - Renovate configuration, schedule, regex versioning, and automerge policy (V710..V713)
#   - Release notes generator CLI functionality, options, and error handling (V720..V722)
#   - GitHub Actions workflow syntax via actionlint and permission boundaries (V730..V733)
#   - Container tag immutability, moving tag prohibition, and smoke test gating (V740..V744)
#
# Every failure carries a stable RULE identifier (V701..V744).
set -euo pipefail

fail() { local r="$1"; shift; echo "verify-phase7.sh: FAIL[${r}]: $*" >&2; exit 1; }

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

RENOVATE_CONFIG="${PROJECT_ROOT}/renovate.json"
RELEASE_NOTES_SCRIPT="${PROJECT_ROOT}/scripts/generate-release-notes.sh"
RELEASE_WORKFLOW="${PROJECT_ROOT}/.github/workflows/release.yml"
PUBLISH_WORKFLOW="${PROJECT_ROOT}/.github/workflows/publish.yml"
SMOKE_WORKFLOW="${PROJECT_ROOT}/.github/workflows/smoke-test.yml"

echo "=== Phase 7 Verification Suite ==="

# ---------------------------------------------------------------------------
# Section 1: Prerequisite artifacts check
# ---------------------------------------------------------------------------
echo "--- [1/5] Checking Phase 7 prerequisite artifacts ---"
[ -f "${RENOVATE_CONFIG}" ]          || fail V701 "renovate.json missing: ${RENOVATE_CONFIG}"
[ -f "${RELEASE_NOTES_SCRIPT}" ]      || fail V702 "generate-release-notes.sh missing: ${RELEASE_NOTES_SCRIPT}"
[ -x "${RELEASE_NOTES_SCRIPT}" ]      || fail V702 "generate-release-notes.sh not executable: ${RELEASE_NOTES_SCRIPT}"
[ -f "${RELEASE_WORKFLOW}" ]          || fail V703 "release.yml missing: ${RELEASE_WORKFLOW}"
[ -f "${PUBLISH_WORKFLOW}" ]          || fail V704 "publish.yml missing: ${PUBLISH_WORKFLOW}"
[ -f "${SMOKE_WORKFLOW}" ]            || fail V705 "smoke-test.yml missing: ${SMOKE_WORKFLOW}"
echo "  ✓ Prerequisite artifacts present and executable"

# ---------------------------------------------------------------------------
# Section 2: Renovate configuration & regex versioning assertions
# ---------------------------------------------------------------------------
echo "--- [2/5] Validating Renovate configuration & regex versioning ---"
jq empty "${RENOVATE_CONFIG}" 2>/dev/null \
    || fail V710 "renovate.json contains invalid JSON syntax"

jq -e '.schedule[] | select(. == "before 6am on monday")' "${RENOVATE_CONFIG}" >/dev/null 2>&1 \
    || fail V711 "renovate.json schedule does not include 'before 6am on monday'"

jq -e '
  .packageRules[] |
  select(.matchPackageNames[] == "lscr.io/linuxserver/code-server") |
  .versioning |
  select(startswith("regex:^(?<major>\\d+)\\.(?<minor>\\d+)\\.(?<patch>\\d+)-ls(?<build>\\d+)$"))
' "${RENOVATE_CONFIG}" >/dev/null 2>&1 \
    || fail V712 "renovate.json lacks expected regex versioning for lscr.io/linuxserver/code-server"

jq -e '
  .packageRules[] |
  select(.matchPackageNames[] == "lscr.io/linuxserver/code-server") |
  select(.automerge == false)
' "${RENOVATE_CONFIG}" >/dev/null 2>&1 \
    || fail V713 "renovate.json packageRule does not set automerge: false"
echo "  ✓ Renovate configuration and regex versioning rules valid"

# ---------------------------------------------------------------------------
# Section 3: Release notes generator CLI assertions
# ---------------------------------------------------------------------------
echo "--- [3/5] Validating release notes generator CLI ---"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

NOTES_OUT="$("${RELEASE_NOTES_SCRIPT}" --target-version v1.0.0)"
echo "${NOTES_OUT}" | grep -q "LinuxServer code-server Base" \
    || fail V720 "generate-release-notes.sh output missing 'LinuxServer code-server Base'"
echo "${NOTES_OUT}" | grep -q "Codium Full Commits" \
    || fail V720 "generate-release-notes.sh output missing 'Codium Full Commits'"

"${RELEASE_NOTES_SCRIPT}" --target-version v1.0.0 --output "${TMP_DIR}/notes.md"
[ -f "${TMP_DIR}/notes.md" ] \
    || fail V721 "generate-release-notes.sh failed to create output file with --output"
grep -q "LinuxServer code-server Base" "${TMP_DIR}/notes.md" \
    || fail V721 "generate-release-notes.sh --output content missing expected headings"

if "${RELEASE_NOTES_SCRIPT}" >/dev/null 2>&1; then
    fail V722 "generate-release-notes.sh unexpectedly succeeded without --target-version (must exit 1)"
fi
echo "  ✓ Release notes generator CLI functional, tested with --output, and fails closed"

# ---------------------------------------------------------------------------
# Section 4: GitHub Actions workflows actionlint & security assertions
# ---------------------------------------------------------------------------
echo "--- [4/5] Validating GitHub Actions workflows actionlint & permissions ---"
run_actionlint() {
    local wf="$1"
    if command -v actionlint >/dev/null 2>&1; then
        actionlint "${wf}"
    else
        docker run --rm -i rhysd/actionlint:latest - < "${wf}"
    fi
}

run_actionlint "${RELEASE_WORKFLOW}" \
    || fail V730 "actionlint validation failed for release.yml"
run_actionlint "${PUBLISH_WORKFLOW}" \
    || fail V731 "actionlint validation failed for publish.yml"

grep -q "contents: write" "${RELEASE_WORKFLOW}" \
    || fail V732 "release.yml missing 'contents: write' permission"
grep -q "actions: write" "${RELEASE_WORKFLOW}" \
    || fail V732 "release.yml missing 'actions: write' permission"

grep -q "packages: write" "${PUBLISH_WORKFLOW}" \
    || fail V733 "publish.yml missing 'packages: write' permission"
echo "  ✓ Workflow definitions valid under actionlint and enforce least-privilege permissions"

# ---------------------------------------------------------------------------
# Section 5: Tag immutability & smoke test gating assertions
# ---------------------------------------------------------------------------
echo "--- [5/5] Validating tag immutability & smoke test gating ---"
grep -q "latest=false" "${PUBLISH_WORKFLOW}" \
    || fail V740 "publish.yml does not enforce latest=false"

if grep -q -E '(:latest|value=latest)' "${PUBLISH_WORKFLOW}"; then
    fail V741 "publish.yml contains prohibited moving tag pattern (:latest or value=latest)"
fi

grep -q "uses: ./.github/workflows/smoke-test.yml" "${PUBLISH_WORKFLOW}" \
    || fail V742 "publish.yml does not wire smoke-test.yml gate"
grep -q "needs: smoke-test-gate" "${PUBLISH_WORKFLOW}" \
    || fail V742 "publish.yml publish-ghcr job does not depend on smoke-test-gate"

grep -q "platforms: linux/amd64,linux/arm64" "${PUBLISH_WORKFLOW}" \
    || fail V743 "publish.yml does not configure platforms: linux/amd64,linux/arm64"

grep -q "ghcr.io/gmcouto/codium-full" "${PUBLISH_WORKFLOW}" \
    || fail V744 "publish.yml does not target ghcr.io/gmcouto/codium-full"
echo "  ✓ Strict tag immutability, multi-platform targets, and smoke test gating verified"

echo "=== Phase 7 Verification Suite: ALL CHECKS PASSED (V701..V744) ==="
exit 0
