# syntax=docker/dockerfile:1.7
# aoe-sandbox: custom multi-arch sandbox image for agent-of-empires.
# Runs as root with HOME=/root to match aoe's hardcoded container home.
FROM debian:stable

ARG TARGETARCH
ENV DEBIAN_FRONTEND=noninteractive

# Core apt deps (single layer). gnupg/fzf intentionally omitted (see design spec).
# xz-utils is needed to extract the Node .tar.xz tarball later.
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    git \
    ca-certificates \
    ripgrep \
    openssh-client \
    unzip \
    xz-utils \
    jq \
    build-essential \
    pkg-config \
    libssl-dev \
    clang \
    libclang-dev \
    cmake \
    locales \
    fd-find \
    just \
    python3 \
    python3-pip \
    python3-venv \
    default-jdk \
    r-base \
 && ln -s "$(command -v fdfind)" /usr/local/bin/fd \
 && sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen \
 && locale-gen \
 && rm -rf /var/lib/apt/lists/*

ENV LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    IS_SANDBOX=1

# Go (official tarball; apt's Go is too old for current gopls). Latest stable.
RUN set -eux; \
    GO_VERSION="$(curl -fsSL https://go.dev/VERSION?m=text | head -1)"; \
    curl -fsSL "https://go.dev/dl/${GO_VERSION}.linux-${TARGETARCH}.tar.gz" -o /tmp/go.tgz; \
    tar -C /usr/local -xzf /tmp/go.tgz; \
    rm /tmp/go.tgz
ENV PATH="/usr/local/go/bin:/root/go/bin:${PATH}"

# Rust via rustup, with rust-analyzer (LSP) and clippy components.
RUN set -eux; \
    curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs | sh -s -- -y --no-modify-path; \
    . "$HOME/.cargo/env"; \
    rustup component add rust-analyzer clippy
ENV PATH="/root/.cargo/bin:${PATH}"

# Node.js LTS (official tarball). For JS/TS work, qmd (better-sqlite3), and the TS/pyright LSPs.
RUN set -eux; \
    NODE_ARCH="$(case "${TARGETARCH}" in amd64) echo x64 ;; arm64) echo arm64 ;; *) echo "unsupported ${TARGETARCH}" >&2; exit 1 ;; esac)"; \
    NODE_VERSION="$(curl -fsSL https://nodejs.org/dist/index.json | jq -r '[.[] | select(.lts != false)][0].version')"; \
    curl -fsSL "https://nodejs.org/dist/${NODE_VERSION}/node-${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz" -o /tmp/node.tar.xz; \
    tar -C /usr/local --strip-components=1 -xJf /tmp/node.tar.xz; \
    rm /tmp/node.tar.xz

# Bun (fast JS runtime). Installer auto-detects arch.
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:${PATH}"

# Bazel via bazelisk (latest release binary).
RUN set -eux; \
    curl -fsSL "https://github.com/bazelbuild/bazelisk/releases/latest/download/bazelisk-linux-${TARGETARCH}" \
      -o /usr/local/bin/bazel; \
    chmod +x /usr/local/bin/bazel

# GitHub CLI (release tarball; avoids the apt repo + gnupg). Latest version via API.
RUN set -eux; \
    GH_VERSION="$(curl -fsSL https://api.github.com/repos/cli/cli/releases/latest | jq -r .tag_name | sed 's/^v//')"; \
    curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${TARGETARCH}.tar.gz" -o /tmp/gh.tgz; \
    tar -C /tmp -xzf /tmp/gh.tgz; \
    install -m 0755 "/tmp/gh_${GH_VERSION}_linux_${TARGETARCH}/bin/gh" /usr/local/bin/gh; \
    rm -rf /tmp/gh.tgz "/tmp/gh_${GH_VERSION}_linux_${TARGETARCH}"

# Agent CLIs. Native installers auto-detect arch. No other agents, no ACP adapters (no cockpit).
RUN curl -fsSL https://claude.ai/install.sh | bash
ENV PATH="/root/.local/bin:${PATH}"
RUN curl -fsSL https://opencode.ai/install | bash
ENV PATH="/root/.opencode/bin:${PATH}"

# qmd: local markdown search engine. Native better-sqlite3 build uses the
# Node + build-essential + python3 already installed.
RUN npm install -g @tobilu/qmd

# search-cli (Rust): multi-provider search used by the deep-research skill.
# Installed from the alepar/search-cli fork, which switches self_update + readability
# to rustls so the native-tls/openssl-sys stack no longer collides with rquest's
# BoringSSL at link time (upstream paperfoot/search-cli won't build on Linux).
# --locked uses the fork's Cargo.lock (openssl-free). Installs `search` into /root/.cargo/bin.
RUN cargo install --git https://github.com/alepar/search-cli --rev 0c8da5c --locked

# deep-research skill runtime deps: WeasyPrint (PDF export) + its native libs.
# (The skill itself is synced from the host by aoe, not baked here.)
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpango-1.0-0 \
    libpangocairo-1.0-0 \
    libgdk-pixbuf-2.0-0 \
    libcairo2 \
    libffi8 \
    libharfbuzz0b \
 && rm -rf /var/lib/apt/lists/* \
 && pip install --break-system-packages weasyprint

WORKDIR /workspace
CMD ["sleep", "infinity"]
