#!/usr/bin/env bash
# Atomic Phase 5 candidate-bundle preparation entry point.
#
# Resolves the current stable/default channels for all eight AI tools once into
# an exact, two-architecture candidate bundle at:
#   .build/ai-tools/candidate-resolution.json
#
# This directory is gitignored (D-03: generated artifacts never tracked) but is
# NOT excluded from the Docker build context so Phase 6 / Plan 05-04 can inject
# the identical bundle into both amd64 and arm64 image builds.
#
# Atomicity contract (D-21): a temp sibling is fully resolved and validated
# before it is atomically renamed over the previous bundle. A failed resolution
# or a failed validation leaves the prior valid bundle untouched.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
OUT_DIR="${PROJECT_ROOT}/.build/ai-tools"
OUT_FILE="${OUT_DIR}/candidate-resolution.json"

usage() {
    cat >&2 <<'EOF'
usage: prepare-ai-tools-resolution.sh
  Resolves all eight tools and atomically writes .build/ai-tools/candidate-resolution.json.
  No arguments. The bundle is validated in full before it replaces any prior bundle.
EOF
    exit 2
}

for a in "$@"; do
    case "${a}" in
        -h|--help) usage ;;
        *) echo "prepare-ai-tools-resolution.sh: unknown option: ${a}" >&2; usage ;;
    esac
done

RESOLVER="${SCRIPT_DIR}/resolve-ai-tools.sh"
VALIDATOR="${SCRIPT_DIR}/validate-ai-tool-resolution.sh"

[ -x "${RESOLVER}" ] || { echo "prepare: resolver missing: ${RESOLVER}" >&2; exit 1; }
[ -x "${VALIDATOR}" ] || { echo "prepare: validator missing: ${VALIDATOR}" >&2; exit 1; }

mkdir -p "${OUT_DIR}"
TMP_FILE="$(mktemp "${OUT_DIR}/.candidate-resolution.XXXXXX.json")"
trap 'rm -f -- "${TMP_FILE}"' EXIT

# Resolve into the temp staging file (same directory => same filesystem for an
# atomic rename), then apply the full validator to the staged bundle.
"${RESOLVER}" --output "${TMP_FILE}"

ARCH_ARGS="--architectures amd64,arm64"
SELF_TEST_ARGS="--self-schema-test"
# shellcheck disable=SC2086
"${VALIDATOR}" "${TMP_FILE}" ${ARCH_ARGS}
"${VALIDATOR}" "${TMP_FILE}" ${ARCH_ARGS} ${SELF_TEST_ARGS} >/dev/null

# Bundle passed full validation: atomically replace the prior valid bundle.
chmod 0644 "${TMP_FILE}"
cp "${TMP_FILE}" "${OUT_FILE}.tmp"   # cp gives an atomic-ish rename source on all filesystems
mv -f "${OUT_FILE}.tmp" "${OUT_FILE}"

# Confirm the committed bundle is exactly the validated one.
cmp -s "${TMP_FILE}" "${OUT_FILE}" || { echo "prepare: internal atomicity check failed" >&2; exit 1; }

echo "prepare-ai-tools-resolution.sh: wrote ${OUT_FILE}" >&2
trap - EXIT
rm -f -- "${TMP_FILE}"