FROM lscr.io/linuxserver/code-server:4.137.0-ls364

ARG TARGETPLATFORM
ARG TARGETARCH
ARG RUST_VERSION=1.85.1
ARG RUSTUP_VERSION=1.28.2
ARG GO_VERSION=1.24.1

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Configure official vendor apt repositories (NodeSource Node 22, Docker CE, GitHub CLI)
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
    && mkdir -p -m 0755 /etc/apt/keyrings \
    && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
    && curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" > /etc/apt/sources.list.d/nodesource.list \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu noble stable" > /etc/apt/sources.list.d/docker.list \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Install compilation tools, runtimes, native development libraries, Docker CLI, and utilities
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        build-essential \
        nodejs \
        python3 \
        python3-pip \
        python3-venv \
        python3-dev \
        pkg-config \
        libssl-dev \
        libglib2.0-dev \
        libgdk-pixbuf-2.0-dev \
        libpango1.0-dev \
        libatk1.0-dev \
        libgtk-3-dev \
        libjavascriptcoregtk-4.1-dev \
        libsoup-3.0-dev \
        libwebkit2gtk-4.1-dev \
        docker-ce-cli \
        docker-compose-plugin \
        docker-buildx-plugin \
        gh \
        ripgrep \
        fd-find \
        fzf \
        jq \
        zoxide \
    && ln -sf "$(command -v fdfind)" /usr/local/bin/fd \
    && (apt-get purge -y tmux screen || true) \
    && node --version | grep -E '^v22\.' \
    && python3 --version | grep -E '3\.12\.' \
    && docker --version \
    && gh --version && rg --version && fd --version && fzf --version && jq --version && zoxide --version \
    && ! command -v tmux && ! command -v screen \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

RUN if [ -f /app/code-server/lib/vscode/product.json ]; then \
        jq '. + {"extensionsGallery": {"serviceUrl": "https://marketplace.visualstudio.com/_apis/public/gallery", "itemUrl": "https://marketplace.visualstudio.com/items", "cacheUrl": "https://vscode.blob.core.windows.net/gallery/index"}}' \
            /app/code-server/lib/vscode/product.json > /tmp/product.json \
        && mv /tmp/product.json /app/code-server/lib/vscode/product.json; \
    fi

COPY rootfs/ /

# The upstream image may include build-time CLI state under its /config volume.
# Runtime initialization owns /config, so keep the derived image layer pristine.
RUN shopt -s dotglob nullglob \
    && config_entries=(/config/*) \
    && if ((${#config_entries[@]})); then rm -rf -- "${config_entries[@]}"; fi

# Install a pinned Rust toolchain using the checksummed official rustup binary.
# rustup hashes: https://static.rust-lang.org/rustup/archive/1.28.2/<target>/rustup-init.sha256
RUN case "${TARGETARCH}" in \
        amd64) rust_arch=x86_64-unknown-linux-gnu; rustup_sha256=20a06e644b0d9bd2fbdbfd52d42540bdde820ea7df86e92e533c073da0cdd43c ;; \
        arm64) rust_arch=aarch64-unknown-linux-gnu; rustup_sha256=e3853c5a252fca15252d07cb23a1bdd9377a8c6f3efa01531109281ae47f841c ;; \
        *) echo "Unsupported TARGETARCH for Rust: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && mkdir -p /opt/rust \
    && curl --proto '=https' --tlsv1.2 -fsSL "https://static.rust-lang.org/rustup/archive/${RUSTUP_VERSION}/${rust_arch}/rustup-init" -o /tmp/rustup-init \
    && echo "${rustup_sha256}  /tmp/rustup-init" | sha256sum -c - \
    && chmod +x /tmp/rustup-init \
    && HOME=/root RUSTUP_HOME=/opt/rust/rustup CARGO_HOME=/opt/rust/cargo /tmp/rustup-init -y --default-toolchain "${RUST_VERSION}" --profile minimal --no-modify-path \
    && rm -f /tmp/rustup-init \
    && chmod -R a+rX /opt/rust \
    && ln -sf /opt/rust/cargo/bin/* /usr/local/bin/ \
    && rm -rf /opt/rust/cargo/registry /opt/rust/cargo/git \
    && su -s /bin/bash abc -c "RUSTUP_HOME=/opt/rust/rustup CARGO_HOME=/opt/rust/cargo rustc --version | grep -F 'rustc ${RUST_VERSION}' && RUSTUP_HOME=/opt/rust/rustup CARGO_HOME=/opt/rust/cargo cargo --version"

# Install the checksummed Go toolchain into /usr/local/go and symlink its binaries.
# Go hashes: https://go.dev/dl/?mode=json&include=all
RUN case "${TARGETARCH}" in \
        amd64) go_sha256=cb2396bae64183cdccf81a9a6df0aea3bce9511fc21469fb89a0c00470088073 ;; \
        arm64) go_sha256=8df5750ffc0281017fb6070fba450f5d22b600a02081dceef47966ffaf36a3af ;; \
        *) echo "Unsupported TARGETARCH for Go: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${TARGETARCH}.tar.gz" -o /tmp/go.tar.gz \
    && echo "${go_sha256}  /tmp/go.tar.gz" | sha256sum -c - \
    && rm -rf /usr/local/go \
    && tar -C /usr/local -xzf /tmp/go.tar.gz \
    && rm -f /tmp/go.tar.gz \
    && ln -sf /usr/local/go/bin/* /usr/local/bin/ \
    && su -s /bin/bash abc -c "go version | grep -F 'go${GO_VERSION}'"


ENV PNPM_HOME="/config/.local/share/pnpm" \
    GOROOT="/usr/local/go" \
    GOPATH="/config/go" \
    RUSTUP_HOME="/opt/rust/rustup" \
    PATH="/usr/local/go/bin:/opt/rust/cargo/bin:/config/.local/share/pnpm:/usr/local/bin:/usr/bin:/bin${PATH:+:$PATH}"
