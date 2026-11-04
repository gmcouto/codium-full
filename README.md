# Codium Full

Codium Full is a ready-to-use development environment based on LinuxServer's code-server image. It includes common language toolchains, Docker tools, AI coding assistants, SSH access, and shell utilities, so the container is useful as soon as it starts.

Images are available for `linux/amd64` and `linux/arm64` from:

```text
ghcr.io/gmcouto/codium-full
```

## Run it

```bash
docker run -d \
  --name codium-full \
  -p 8443:8443 \
  -p 2222:2222 \
  -v codium-config:/config \
  ghcr.io/gmcouto/codium-full:v1.0.0
```

Open `http://localhost:8443` to use code-server. SSH listens on port `2222` and uses key authentication.

## Included

- Node.js, Python, Go, Rust, pnpm, Docker CLI, and GitHub CLI
- Claude Code, OpenClaude, Cursor Agent, Copilot CLI, Codex CLI, OpenCode, Antigravity, and Herdr
- OpenSSH, jq, ripgrep, fd, fzf, and zoxide
- Microsoft extension marketplace support

## Releases

Releases use immutable version tags such as `v1.0.0`. Each release is tested on amd64 and arm64 before it is published to GHCR. The project does not publish `latest`, major, or minor moving tags.

To create a release, run the **Release Authoring** workflow from the GitHub Actions page and enter a new version number.

## Local checks

```bash
./scripts/lint.sh
```

The repository also contains smoke tests used by the release workflow.

## Third-party notices

Notices for bundled tools are included in the image and repository.
