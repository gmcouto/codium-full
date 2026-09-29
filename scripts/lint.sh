#!/usr/bin/env bash
# Fast static PR linting runner (REL-02)
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

echo "=== [1/5] Dockerfile Linting (Hadolint) ==="
if command -v hadolint >/dev/null 2>&1; then
    hadolint Dockerfile
else
    docker run --rm -i hadolint/hadolint:v2.15.1 hadolint --ignore DL3008 --ignore DL3016 --ignore SC2174 - < Dockerfile
fi
echo "  ✓ Dockerfile clean"

echo "=== [2/5] Shell Script Linting (ShellCheck) ==="
SHELL_FILES=(
    scripts/*.sh
    rootfs/etc/profile.d/*.sh
    rootfs/usr/local/bin/npm
    rootfs/usr/local/bin/npx
    rootfs/usr/local/bin/yarn
)
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -x "${SHELL_FILES[@]}"
else
    DISABLE_CODES=$(grep '^disable=' .shellcheckrc | cut -d= -f2)
    for file in "${SHELL_FILES[@]}"; do
        [ -f "$file" ] || continue
        docker run --rm -i koalaman/shellcheck:v0.11.0 -s bash -e "${DISABLE_CODES}" - < "$file"
    done
fi
echo "  ✓ Shell scripts clean"

echo "=== [3/5] GitHub Actions Workflow Linting (actionlint) ==="
WORKFLOW_FILES=(.github/workflows/*.yml)
if [ -e "${WORKFLOW_FILES[0]}" ]; then
    if command -v actionlint >/dev/null 2>&1; then
        actionlint "${WORKFLOW_FILES[@]}"
    else
        for wf in "${WORKFLOW_FILES[@]}"; do
            [ -f "$wf" ] || continue
            docker run --rm -i rhysd/actionlint:latest - < "$wf"
        done
    fi
    echo "  ✓ Workflow files clean"
else
    echo "  (No workflow files found; skipping)"
fi

echo "=== [4/5] Docker Compose Config Validation ==="
TEST_PASSWORD=dummypassword docker compose -f docker-compose.test.yml config -q
echo "  ✓ Compose configuration clean"

echo "=== [5/5] JSON Syntax Validation ==="
while IFS= read -r -d '' jf; do
    jq empty "$jf" || { echo "ERROR: Invalid JSON in $jf" >&2; exit 1; }
done < <(find . -maxdepth 1 -name '*.json' -print0; find ai-tools rootfs -name '*.json' -print0)
echo "  ✓ JSON configurations clean"

echo "=== ALL STATIC CHECKS PASSED ==="
exit 0
