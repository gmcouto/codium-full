---
phase: 04-pnpm-compatibility-surface
plan: 01
subsystem: package-management
tags: [pnpm, npm, npx, yarn, docker]
requires:
  - phase: 01-foundation-and-build-invariants
    provides: Node.js runtime and canonical system image layers
provides:
  - Build-time pnpm and Yarn installation with native escape-hatch links
  - POSIX npm, npx, and yarn compatibility shims
  - pnpm-first canonical PATH across shell entrypoints
affects: [phase-04-plan-02, phase-05-rolling-ai-cli-acquisition]
actuals:
  tokens: 2000
  tasks: 2
  commits: 1
tech-stack:
  added: [pnpm, yarn]
  patterns: [fail-closed POSIX command shims, explicit native bypass]
key-files:
  created:
    - rootfs/usr/local/bin/npm
    - rootfs/usr/local/bin/npx
    - rootfs/usr/local/bin/yarn
  modified:
    - Dockerfile
    - rootfs/etc/profile.d/00-codium-env.sh
    - rootfs/etc/bash.bashrc
key-decisions:
  - "Install pnpm and Yarn during image construction rather than using Corepack or runtime downloads."
  - "Keep native npm, npx, and Yarn reachable through explicit links and CODIUM_BYPASS_SHIMS=1."
requirements-completed: [SHIM-01, SHIM-02, SHIM-03, SHIM-04]
coverage:
  - id: D1
    description: pnpm is installed at build time and receives first-class PATH precedence.
    requirement: SHIM-01
    verification:
      - kind: other
        ref: "bash -n rootfs/etc/profile.d/00-codium-env.sh rootfs/etc/bash.bashrc; Dockerfile pnpm --version assertion"
        status: pass
    human_judgment: false
  - id: D2
    description: npm, npx, and yarn translate supported operations to pnpm.
    requirement: SHIM-02
    verification:
      - kind: other
        ref: "sh -n rootfs/usr/local/bin/{npm,npx,yarn}"
        status: pass
    human_judgment: false
  - id: D3
    description: Unsupported operations fail closed with standardized guidance.
    requirement: SHIM-03
    verification:
      - kind: other
        ref: "rootfs/usr/local/bin/{npm,npx,yarn} source inspection"
        status: pass
    human_judgment: false
  - id: D4
    description: Native package-manager bypasses are available.
    requirement: SHIM-04
    verification:
      - kind: other
        ref: "Dockerfile native-link declarations and CODIUM_BYPASS_SHIMS guards"
        status: pass
    human_judgment: false
---

# Phase 4 Plan 1: pnpm Compatibility Surface Summary

Build-time pnpm installation and fail-closed POSIX compatibility shims for npm, npx, and yarn.

## Performance

- **Tasks:** 2
- **Files created:** 3
- **Files modified:** 3

## Accomplishments

- Added build-time pnpm/Yarn installation, version assertions, native links, and pnpm-first PATH policy.
- Added npm, npx, and yarn shims covering common local package workflows and explicit unsupported-command failures.
- Preserved native escape hatches through `*-native` links and `CODIUM_BYPASS_SHIMS=1`.

## Task Commits

1. **Task 1: Install pnpm and establish PATH and native escape hatches** - `bf0ddca`
2. **Task 2: Implement fail-closed npm, npx, and yarn shims** - `bf0ddca`

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None.

## Next Phase Readiness

Ready for Plan 04-02 verification suite and compose harness integration.

---
*Phase: 04-pnpm-compatibility-surface*
*Completed: 2026-09-28*
