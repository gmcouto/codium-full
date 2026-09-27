FROM lscr.io/linuxserver/code-server:4.137.0-ls364

ARG TARGETPLATFORM
ARG TARGETARCH

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
    && ln -sf $(which fdfind) /usr/local/bin/fd \
    && apt-get purge -y tmux screen || true \
    && node --version | grep -E '^v22\.' \
    && python3 --version | grep -E '3\.12\.' \
    && docker --version \
    && gh --version && rg --version && fd --version && fzf --version && jq --version \
    && ! command -v tmux && ! command -v screen \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Install Rust (stable) into /opt/rust and symlink to /usr/local/bin
RUN mkdir -p /opt/rust \
    && curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | HOME=/root RUSTUP_HOME=/opt/rust/rustup CARGO_HOME=/opt/rust/cargo sh -s -- -y --default-toolchain stable --profile minimal --no-modify-path \
    && chmod -R a+rX /opt/rust \
    && ln -sf /opt/rust/cargo/bin/* /usr/local/bin/ \
    && rm -rf /opt/rust/cargo/registry /opt/rust/cargo/git \
    && su -s /bin/bash abc -c 'rustc --version && cargo --version'

# Install Go toolchain into /usr/local/go and symlink to /usr/local/bin
RUN curl -fsSL "https://go.dev/dl/go1.24.1.linux-${TARGETARCH}.tar.gz" -o /tmp/go.tar.gz \
    && tar -C /usr/local -xzf /tmp/go.tar.gz \
    && rm -f /tmp/go.tar.gz \
    && ln -sf /usr/local/go/bin/* /usr/local/bin/ \
    && su -s /bin/bash abc -c 'go version'

# Global container environment configuration
ENV RUSTUP_HOME=/opt/rust/rustup \
    GOROOT=/usr/local/go \
    GOPATH=/config/go \
    PATH=/usr/local/go/bin:/opt/rust/cargo/bin:${PATH}
