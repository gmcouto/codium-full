# Codium Full

## What This Is

Codium Full is a prebuilt, batteries-included development-machine image derived from LinuxServer's code-server image. It replaces a slow runtime Docker Mods setup with an image that starts ready to use, containing the language toolchains, Docker tooling, terminal utilities, AI coding CLIs, shell integrations, Microsoft extension gallery access, and SSH service needed for daily development.

The image is maintained and released from `git@github.com:gmcouto/codium-full.git`, published for amd64 and arm64 to `ghcr.io/gmcouto/codium-full`, and automated through GitHub Actions and Renovate.

## Core Value

Starting the container provides the complete development environment immediately instead of spending roughly 30 minutes installing Docker Mods and tools during initialization.

## Requirements

### Validated

(None yet — ship to validate)

### Active

- [ ] Build a LinuxServer code-server-derived image with the tools and configurations currently supplied by the referenced Docker Mods baked into image layers.
- [ ] Bake in Node.js, NVM-equivalent functionality where required, pnpm, Docker CLI, Python, Rust, Go, package-install support, extension arguments support, AI coding tools, and the requested native development libraries.
- [ ] Install the current/latest AI tools represented by `code-server-ai-tools` at image build time: Claude Code, OpenClaude, Cursor Agent, GitHub Copilot CLI, OpenAI Codex CLI, OpenCode, Antigravity CLI, Herdr, GitHub CLI, fd, ripgrep, and fzf.
- [ ] Exclude tmux and screen because Herdr provides the desired terminal multiplexing workflow.
- [ ] Provide custom `npm` and `yarn` compatibility shims that translate common package-management operations to pnpm, with pnpm preferred first in PATH.
- [ ] Enable the Microsoft Visual Studio Marketplace extension gallery automatically.
- [ ] Install OpenSSH server and run it autonomously under s6 on container port 2222 with key-only authentication; users manage `authorized_keys` through their persisted home or a mounted volume.
- [ ] Install jq and zoxide, expose zoxide through the `z` command, and configure Bash integration and completion.
- [ ] Configure Bash tab completion for fzf.
- [ ] Build and publish `linux/amd64` and `linux/arm64` images to `ghcr.io/gmcouto/codium-full` when a SemVer tag is pushed.
- [ ] Publish only the immutable full release tag, such as `v1.2.3`, for each release.
- [ ] Provide a manually runnable release workflow that accepts a new SemVer, generates release notes describing LinuxServer and code-server changes since the previous release, and creates the tag and GitHub Release.
- [ ] Keep image packaging/testing separate: a tag-triggered workflow builds, smoke-tests, and publishes the image.
- [ ] Configure Renovate to check the pinned LinuxServer base-image version weekly and open an update pull request.
- [ ] Run container/workflow linting on ordinary and Renovate pull requests; reserve multi-architecture builds and runtime smoke tests for tagged releases.
- [ ] Runtime smoke tests verify code-server, SSH on port 2222, installed tools, pnpm and compatibility shims, PATH precedence, Microsoft gallery configuration, zoxide, and fzf completion.

### Out of Scope

- Docker Mods installed during container initialization — the project exists specifically to eliminate their startup cost.
- tmux and screen — Herdr replaces these tools in this environment.
- Docker Hub publication — v1 publishes only to GHCR.
- Moving `latest`, major, or minor image tags — releases publish only the immutable full SemVer tag.
- Password-based SSH authentication — SSH is key-only.
- Pre-baking user SSH keys — users place keys in their persisted home through code-server or mount them.
- Full image builds for ordinary pull requests — PR validation is lint-only by explicit choice.
- Pinning every AI CLI version — these tools intentionally resolve to their current/latest versions when a release image is built.

## Context

The current setup uses `lscr.io/linuxserver/code-server` with this Docker Mods chain:

`linuxserver/mods:universal-package-install|linuxserver/mods:code-server-extension-arguments|linuxserver/mods:code-server-nodejs|linuxserver/mods:code-server-nvm|linuxserver/mods:universal-docker|linuxserver/mods:code-server-python3|linuxserver/mods:code-server-rust|linuxserver/mods:code-server-pnpm|linuxserver/mods:code-server-golang|ghcr.io/gmcouto/code-server-ai-tools:latest`

The associated package list is:

`pkg-config|libssl-dev|libglib2.0-dev|libgdk-pixbuf-2.0-dev|libpango1.0-dev|libatk1.0-dev|libgtk-3-dev|libjavascriptcoregtk-4.1-dev|libsoup-3.0-dev|libwebkit2gtk-4.1-dev`

The local reference implementation lives at `/mnt/external/appdata/code-server/workspace/code-server-ai-tools`. It installs packages and AI CLIs through s6 initialization, which contributes heavily to startup time. Its useful behavior must be translated into Docker build layers while preserving LinuxServer conventions for `/config`, `PUID`, `PGID`, Bash, and s6-overlay.

The reference mod currently installs `screen`, `tmux`, `fd-find`, `ripgrep`, `fzf`, and `gh`; npm-distributed Claude Code, OpenClaude, Copilot CLI, Codex CLI, and OpenCode; plus Cursor Agent, Antigravity, and Herdr through their official installers. Codium Full retains that toolset except for screen and tmux, and adds OpenSSH, jq, zoxide, shell completion, Microsoft gallery defaults, and package-manager compatibility shims.

Releases use independent project SemVer even though LinuxServer base updates arrive through Renovate. The release workflow should compare the newly merged base/code-server state to the previous project release and incorporate those upstream changes into release notes before creating the tag. The tag event then starts the independent packaging, testing, and GHCR publication workflow.

## Constraints

- **Base image**: Derive from a version-tagged LinuxServer code-server image — retain its runtime conventions while allowing Renovate to propose weekly updates.
- **Architectures**: Support both `linux/amd64` and `linux/arm64` — all baked tools and installer paths must work on both architectures.
- **Startup performance**: Toolchains and applications must be installed at build time — startup must not repeat the previous Docker Mods installation workload.
- **Runtime model**: Preserve LinuxServer s6-overlay, `/config` persistence, and `PUID`/`PGID` behavior — SSH and code-server must coexist under the base image's service model.
- **Node package management**: pnpm is the real package manager and precedes alternatives in PATH — custom npm/yarn shims cover common install, add, remove, update, run, exec, and related workflows.
- **Rolling tools**: AI tools install at their current/latest releases during tagged image builds — release artifacts are fixed once published, but rebuilding later can resolve newer tools.
- **Security**: SSH listens on container port 2222 with password authentication disabled — users provide authorized keys at runtime.
- **Registry**: Publish only to GHCR under `ghcr.io/gmcouto/codium-full` — no Docker Hub support in v1.
- **Release tags**: Publish only complete immutable SemVer tags — no moving channel tags.
- **Pull-request cost**: Ordinary and Renovate pull requests run lint-only checks — release tags bear the multi-architecture build and runtime smoke-test cost.

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Build a derived LinuxServer code-server image | Preserves familiar LinuxServer behavior while eliminating runtime mod installation | — Pending |
| Bake the complete mod-derived environment into image layers | Container initialization currently takes about 30 minutes | — Pending |
| Publish amd64 and arm64 images | Supports common x86 servers and ARM hosts | — Pending |
| Use independent SemVer releases | The complete image has its own release lifecycle separate from LinuxServer's tags | — Pending |
| Pin the LinuxServer base by version tag | Gives Renovate a clear weekly update target without digest-only complexity | — Pending |
| Install latest AI tools during release builds | Keeps coding agents fresh without maintaining individual version pins | — Pending |
| Replace Nub with custom npm/yarn-to-pnpm shims | Nub does not provide the requested global default-to-pnpm behavior for unpinned projects | — Pending |
| Exclude tmux and screen | Herdr is the selected terminal multiplexer | — Pending |
| Run SSH through s6 on port 2222 with key-only auth | Provides autonomous remote access without embedding credentials | — Pending |
| Split release creation from tag-triggered packaging | Allows deliberate SemVer and generated notes while keeping image publication deterministic on tags | — Pending |
| Run lint-only checks on pull requests | Explicitly prioritizes lower CI cost; full build and smoke verification happens on release tags | — Pending |
| Publish only full immutable SemVer tags | Avoids moving tags and makes deployed image identity explicit | — Pending |

## Evolution

This document evolves at phase transitions and milestone boundaries.

**After each phase transition** (via `/gsd-transition`):
1. Requirements invalidated? → Move to Out of Scope with reason
2. Requirements validated? → Move to Validated with phase reference
3. New requirements emerged? → Add to Active
4. Decisions to log? → Add to Key Decisions
5. "What This Is" still accurate? → Update if drifted

**After each milestone** (via `/gsd-complete-milestone`):
1. Full review of all sections
2. Core Value check — still the right priority?
3. Audit Out of Scope — reasons still valid?
4. Update Context with current state

---
*Last updated: 2026-09-26 after initialization*
