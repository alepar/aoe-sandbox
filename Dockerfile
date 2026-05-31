# syntax=docker/dockerfile:1.7
# aoe-sandbox: custom multi-arch sandbox image for agent-of-empires.
#
# Multi-stage: a `builder` compiles the from-source tools (search-cli, gopls)
# with the heavy build deps; the final stage carries only runtime toolchains +
# the compiled binaries, so build caches and build-only -dev headers never reach
# the published image. Runs as root with HOME=/root to match aoe's hardcoded
# container home.

############################
# Stage 1: builder
############################
FROM debian:stable AS builder

ARG TARGETARCH
ENV DEBIAN_FRONTEND=noninteractive

# Build-only deps: BoringSSL/bindgen (search-cli's TLS stack) needs clang +
# libclang-dev + cmake; openssl-sys (transitive) needs libssl-dev + pkg-config.
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates git jq xz-utils \
    build-essential pkg-config libssl-dev clang libclang-dev cmake \
 && rm -rf /var/lib/apt/lists/*

# Go (to build gopls)
RUN set -eux; \
    GO_VERSION="$(curl -fsSL https://go.dev/VERSION?m=text | head -1)"; \
    curl -fsSL "https://go.dev/dl/${GO_VERSION}.linux-${TARGETARCH}.tar.gz" -o /tmp/go.tgz; \
    tar -C /usr/local --no-same-owner -xzf /tmp/go.tgz; \
    rm /tmp/go.tgz
ENV PATH="/usr/local/go/bin:/root/.cargo/bin:${PATH}"

# Rust (to build search-cli)
RUN curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs \
    | sh -s -- -y --no-modify-path --profile minimal

# Compile search-cli (alepar fork: rustls + wreq) -> /out/bin/search
RUN cargo install --git https://github.com/alepar/search-cli --rev 0c8da5c --locked --root /out

# Compile gopls -> /out/bin/gopls
RUN GOBIN=/out/bin go install golang.org/x/tools/gopls@latest

############################
# Stage 2: final
############################
FROM debian:stable

ARG TARGETARCH
ENV DEBIAN_FRONTEND=noninteractive

# Runtime apt deps. Build-only -dev headers (libclang-dev, libssl-dev) and the
# clang driver are NOT here - search-cli was compiled in the builder. clangd
# (the C/C++ LSP) brings its own libclang; build-essential/cmake/pkg-config stay
# for runtime native builds. weasyprint native libs included for deep-research.
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl git ca-certificates ripgrep openssh-client unzip xz-utils jq \
    build-essential pkg-config cmake clangd \
    locales fd-find just \
    python3 python3-pip python3-venv \
    default-jdk r-base \
    libpango-1.0-0 libpangocairo-1.0-0 libgdk-pixbuf-2.0-0 libcairo2 libffi8 libharfbuzz0b \
 && ln -s "$(command -v fdfind)" /usr/local/bin/fd \
 && sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen \
 && locale-gen \
 && rm -rf /var/lib/apt/lists/*

ENV LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    IS_SANDBOX=1

# Go (runtime: gopls needs `go` on PATH; agents build Go).
RUN set -eux; \
    GO_VERSION="$(curl -fsSL https://go.dev/VERSION?m=text | head -1)"; \
    curl -fsSL "https://go.dev/dl/${GO_VERSION}.linux-${TARGETARCH}.tar.gz" -o /tmp/go.tgz; \
    tar -C /usr/local --no-same-owner -xzf /tmp/go.tgz; \
    rm /tmp/go.tgz
ENV PATH="/usr/local/go/bin:/root/go/bin:${PATH}"

# Rust (runtime: rust-analyzer needs the toolchain; agents build Rust).
# --profile minimal drops rust-docs (~hundreds of MB); add the LSP + clippy.
# The registry/git caches are build-time only -> removed.
RUN set -eux; \
    curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs \
      | sh -s -- -y --no-modify-path --profile minimal; \
    . "$HOME/.cargo/env"; \
    rustup component add rust-analyzer clippy; \
    rm -rf /root/.cargo/registry /root/.cargo/git
ENV PATH="/root/.cargo/bin:${PATH}"

# Node.js LTS (runtime: qmd, pyright, JS/TS).
RUN set -eux; \
    NODE_ARCH="$(case "${TARGETARCH}" in amd64) echo x64 ;; arm64) echo arm64 ;; *) echo "unsupported ${TARGETARCH}" >&2; exit 1 ;; esac)"; \
    NODE_VERSION="$(curl -fsSL https://nodejs.org/dist/index.json | jq -r '[.[] | select(.lts != false)][0].version')"; \
    curl -fsSL "https://nodejs.org/dist/${NODE_VERSION}/node-${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz" -o /tmp/node.tar.xz; \
    tar -C /usr/local --strip-components=1 --no-same-owner -xJf /tmp/node.tar.xz; \
    rm /tmp/node.tar.xz

# Bun (clean its install cache).
RUN curl -fsSL https://bun.sh/install | bash && rm -rf /root/.bun/install/cache
ENV PATH="/root/.bun/bin:${PATH}"

# Bazel via bazelisk (latest release binary).
RUN set -eux; \
    curl -fsSL "https://github.com/bazelbuild/bazelisk/releases/latest/download/bazelisk-linux-${TARGETARCH}" \
      -o /usr/local/bin/bazel; \
    chmod +x /usr/local/bin/bazel

# GitHub CLI (release tarball; avoids the apt repo + gnupg).
RUN set -eux; \
    GH_VERSION="$(curl -fsSL https://api.github.com/repos/cli/cli/releases/latest | jq -r .tag_name | sed 's/^v//')"; \
    curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${TARGETARCH}.tar.gz" -o /tmp/gh.tgz; \
    tar -C /tmp --no-same-owner -xzf /tmp/gh.tgz; \
    install -m 0755 "/tmp/gh_${GH_VERSION}_linux_${TARGETARCH}/bin/gh" /usr/local/bin/gh; \
    rm -rf /tmp/gh.tgz "/tmp/gh_${GH_VERSION}_linux_${TARGETARCH}"

# Agent CLIs. Native installers auto-detect arch. No ACP adapters (no cockpit).
RUN curl -fsSL https://claude.ai/install.sh | bash
ENV PATH="/root/.local/bin:${PATH}"
RUN curl -fsSL https://opencode.ai/install | bash
ENV PATH="/root/.opencode/bin:${PATH}"

# KB/LSP npm tools: qmd (markdown search) + pyright (Python LSP). Clean npm cache.
RUN npm install -g @tobilu/qmd pyright \
 && npm cache clean --force \
 && rm -rf /root/.npm

# Compiled-from-source binaries copied from the builder (no cargo/go build
# caches land in the final image). search -> cargo bin dir; gopls -> go bin dir.
COPY --from=builder /out/bin/search /root/.cargo/bin/search
COPY --from=builder /out/bin/gopls /root/go/bin/gopls

# deep-research skill runtime dep: WeasyPrint (native libs installed above).
RUN pip install --break-system-packages --no-cache-dir weasyprint

# mykb CLI: download the latest Release asset from alepar/mykb (public repo, so
# no token required). A token is used only if the optional `mykb_token` secret is
# provided, purely to raise the GitHub API rate limit (CI passes GITHUB_TOKEN).
# `set -eu` (no `x`) so shell tracing never echoes a token into build logs.
RUN --mount=type=secret,id=mykb_token \
    set -eu; \
    API="https://api.github.com/repos/alepar/mykb/releases/latest"; \
    if [ -s /run/secrets/mykb_token ]; then \
      AUTH="Authorization: Bearer $(cat /run/secrets/mykb_token)"; \
    else \
      AUTH="X-No-Auth: 1"; \
    fi; \
    ASSET_URL="$(curl -fsSL -H "${AUTH}" "${API}" \
      | jq -r ".assets[] | select(.name==\"mykb-linux-${TARGETARCH}\") | .url")"; \
    test -n "${ASSET_URL}"; \
    curl -fsSL -H "${AUTH}" -H "Accept: application/octet-stream" \
      "${ASSET_URL}" -o /usr/local/bin/mykb; \
    chmod +x /usr/local/bin/mykb

# jdtls (Eclipse JDT Language Server) -> /opt/jdtls, launcher on PATH (uses default-jdk).
# --no-same-owner: the tarball ships files owned by a huge uid that rootless podman
# cannot map into the subuid range; extracting as root keeps unpack working.
RUN set -eux; \
    mkdir -p /opt/jdtls; \
    curl -fsSL https://download.eclipse.org/jdtls/snapshots/jdt-language-server-latest.tar.gz -o /tmp/jdtls.tgz; \
    tar -C /opt/jdtls --no-same-owner -xzf /tmp/jdtls.tgz; \
    rm /tmp/jdtls.tgz; \
    printf '#!/bin/sh\nexec java -jar /opt/jdtls/plugins/org.eclipse.equinox.launcher_*.jar "$@"\n' > /usr/local/bin/jdtls; \
    chmod +x /usr/local/bin/jdtls

# Pre-create the credential-mount dirs aoe bind-mounts at runtime.
RUN mkdir -p \
    /root/.claude \
    /root/.config/opencode \
    /root/.local/share/opencode \
    /root/.ssh

# Expose the toolchain PATH to login shells too (the Docker ENV PATH already
# covers `docker exec`, but a login shell sources /etc/profile which resets PATH).
RUN printf 'export PATH="/root/.local/bin:/root/.opencode/bin:/root/.cargo/bin:/usr/local/go/bin:/root/go/bin:/root/.bun/bin:$PATH"\n' \
    > /etc/profile.d/aoe-path.sh

WORKDIR /workspace
CMD ["sleep", "infinity"]
