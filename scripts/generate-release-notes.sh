#!/usr/bin/env bash
# scripts/generate-release-notes.sh — Generate upstream changelogs and release notes (REL-03)
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

TARGET_VERSION=""
PREV_TAG=""
OUTPUT_FILE=""

usage() {
    local exit_code="${1:-0}"
    cat <<'USAGE'
Usage: generate-release-notes.sh [OPTIONS]

Options:
  --target-version <VERSION>  Target SemVer release version (e.g. v1.0.0)
  --prev-tag <TAG>            Previous release git tag (auto-detected if omitted)
  --output <PATH>             Output file path (default: stdout)
  -h, --help                  Show this help message
USAGE
    exit "${exit_code}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target-version) TARGET_VERSION="$2"; shift 2 ;;
        --prev-tag) PREV_TAG="$2"; shift 2 ;;
        --output) OUTPUT_FILE="$2"; shift 2 ;;
        -h|--help) usage 0 ;;
        *) echo "ERROR: Unknown option '$1'" >&2; exit 1 ;;
    esac
done

if [[ -z "${TARGET_VERSION}" ]]; then
    echo "ERROR: --target-version is required" >&2
    usage 1 >&2
fi

if [[ -z "${PREV_TAG}" ]]; then
    PREV_TAG=$(git tag --sort=-version:refname 2>/dev/null | grep -v "^${TARGET_VERSION}$" | head -n 1 || echo "")
fi

CURR_BASE_TAG=$(sed -nE 's|^FROM lscr\.io/linuxserver/code-server:([0-9a-zA-Z.-]+).*|\1|p' Dockerfile)
if [[ -z "${CURR_BASE_TAG}" ]]; then
    echo "ERROR: Unable to extract base image tag from Dockerfile" >&2
    exit 1
fi
CURR_CODE_VER="${CURR_BASE_TAG%%-*}"

PREV_BASE_TAG=""
if [[ -n "${PREV_TAG}" ]] && git rev-parse --verify "refs/tags/${PREV_TAG}" >/dev/null 2>&1; then
    PREV_BASE_TAG=$(git show "${PREV_TAG}:Dockerfile" 2>/dev/null | sed -nE 's|^FROM lscr\.io/linuxserver/code-server:([0-9a-zA-Z.-]+).*|\1|p' || echo "")
fi

generate_body() {
    echo "## Release ${TARGET_VERSION}"
    echo ""
    echo "### Base Image & Upstream Dependencies"
    echo "- **LinuxServer code-server Base:** \`${CURR_BASE_TAG}\`"
    echo "- **VS Code / code-server Engine:** \`v${CURR_CODE_VER}\`"
    echo ""

    if [[ -n "${PREV_BASE_TAG}" ]]; then
        PREV_CODE_VER="${PREV_BASE_TAG%%-*}"
        if [[ "${PREV_BASE_TAG}" != "${CURR_BASE_TAG}" ]]; then
            echo "### Upstream Changelogs"
            echo "- **LinuxServer Diff:** [\`${PREV_BASE_TAG}...${CURR_BASE_TAG}\`](https://github.com/linuxserver/docker-code-server/compare/${PREV_BASE_TAG}...${CURR_BASE_TAG})"
            echo "- **code-server Diff:** [\`v${PREV_CODE_VER}...v${CURR_CODE_VER}\`](https://github.com/coder/code-server/compare/v${PREV_CODE_VER}...v${CURR_CODE_VER})"
            echo ""
        else
            echo "### Upstream Changelogs"
            echo "Base image unchanged from previous release (\`${CURR_BASE_TAG}\`)."
            echo ""
        fi
    else
        echo "### Upstream Releases"
        echo "- **LinuxServer Release:** [${CURR_BASE_TAG}](https://github.com/linuxserver/docker-code-server/releases/tag/${CURR_BASE_TAG})"
        echo "- **code-server Release:** [v${CURR_CODE_VER}](https://github.com/coder/code-server/releases/tag/v${CURR_CODE_VER})"
        echo ""
    fi

    echo "### Codium Full Commits"
    if [[ -n "${PREV_TAG}" ]]; then
        git log --pretty=format:"* %s (%h)" "${PREV_TAG}..HEAD" || true
    else
        git log --pretty=format:"* %s (%h)" HEAD || true
    fi
    echo ""
}

if [[ -n "${OUTPUT_FILE}" ]]; then
    generate_body > "${OUTPUT_FILE}"
else
    generate_body
fi
