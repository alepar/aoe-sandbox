# Custom aoe-sandbox Image Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a personal multi-arch (amd64+arm64) Debian-based Docker/Podman sandbox image for agent-of-empires, shipping Claude Code + OpenCode, language toolchains + LSPs, and the qmd/mykb/search-cli knowledge tools, published to `ghcr.io/alepar/aoe-sandbox`.

**Architecture:** Single-stage Dockerfile on `debian:stable`, layered cheap->expensive, run as root with `HOME=/root` (matching aoe's hardcoded container home). Built and pushed multi-arch via `docker buildx` in GitHub Actions. Downloaded tools use `TARGETARCH` for arch detection and fetch latest versions dynamically to avoid stale pins. The private `mykb` CLI is downloaded from a GitHub Release produced by a prerequisite workflow in `alepar/mykb` (Phase 0).

**Tech Stack:** Docker/Podman, BuildKit (buildx, build secrets), GitHub Actions, Debian stable, Go/Rust/Node/Bun/Python/Java/R toolchains, GHCR.

**Design spec:** `docs/superpowers/specs/2026-05-30-custom-aoe-sandbox-image-design.md`

**Conventions for this plan:**
- "Build locally" means native-arch single-platform build for fast verification: `docker build -t aoe-sandbox:dev .` (Podman: `podman build -t aoe-sandbox:dev .` works identically). Multi-arch is only exercised in CI (Task 16).
- "Smoke-check" means run a throwaway container and assert a tool reports its version: `docker run --rm aoe-sandbox:dev bash -lc '<cmd>'`.
- The Dockerfile is built incrementally; each task appends a layer, rebuilds (cached up to the new layer), smoke-checks, and commits.
- Commit inside the relevant repo. Phase 0 commits in `~/AleCode/mykb`; all other tasks commit in `~/AleCode/aoe-sandbox`.

---

## Phase 0: mykb CLI release workflow (separate repo: `~/AleCode/mykb`)

Independent prerequisite. Can run in parallel with Tasks 2-15; only Task 14 (mykb download) depends on it.

### Task 1: Add a release workflow that publishes the `mykb` CLI for linux amd64+arm64

**Files:**
- Create: `~/AleCode/mykb/.github/workflows/release-cli.yaml`

- [ ] **Step 1: Verify the cross-compile works locally (both arches)**

Run (in `~/AleCode/mykb`):
```bash
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags "-s -w" -o /tmp/mykb-amd64 ./cmd/mykb
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -ldflags "-s -w" -o /tmp/mykb-arm64 ./cmd/mykb
file /tmp/mykb-amd64 /tmp/mykb-arm64 && rm -f /tmp/mykb-amd64 /tmp/mykb-arm64
```
Expected: one `x86-64` ELF and one `ARM aarch64` ELF, no build errors.

- [ ] **Step 2: Write the release workflow**

Create `~/AleCode/mykb/.github/workflows/release-cli.yaml`:
```yaml
name: Release CLI

on:
  push:
    tags:
      - 'v*'

permissions:
  contents: write

jobs:
  build:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        arch: [amd64, arm64]
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-go@v5
        with:
          go-version-file: go.mod

      - name: Build mykb CLI
        run: |
          CGO_ENABLED=0 GOOS=linux GOARCH=${{ matrix.arch }} \
            go build -trimpath -ldflags "-s -w" \
            -o mykb-linux-${{ matrix.arch }} ./cmd/mykb

      - name: Attach to release
        uses: softprops/action-gh-release@v2
        with:
          files: mykb-linux-${{ matrix.arch }}
```

- [ ] **Step 3: Commit and push the workflow**

Run (in `~/AleCode/mykb`):
```bash
git add .github/workflows/release-cli.yaml
git commit -m "ci: add release workflow publishing mykb CLI for linux amd64/arm64"
git push
```

- [ ] **Step 4: Cut the first release tag**

Run (in `~/AleCode/mykb`):
```bash
git tag v0.1.0 && git push origin v0.1.0
```

- [ ] **Step 5: Verify the release assets exist**

Run:
```bash
gh release view v0.1.0 --repo alepar/mykb
```
Expected: release `v0.1.0` lists assets `mykb-linux-amd64` and `mykb-linux-arm64`. If the workflow is still running, wait and re-run.

---

## Phase 1: Image scaffold + base (repo: `~/AleCode/aoe-sandbox`)

### Task 2: Repo scaffold and Debian base layer

**Files:**
- Create: `~/AleCode/aoe-sandbox/.dockerignore`
- Create: `~/AleCode/aoe-sandbox/Dockerfile`
- Create: `~/AleCode/aoe-sandbox/Justfile`
- Create: `~/AleCode/aoe-sandbox/README.md`

- [ ] **Step 1: Create `.dockerignore`**

```
.git
docs/
*.md
Justfile
```

- [ ] **Step 2: Create the Dockerfile base layer**

Create `~/AleCode/aoe-sandbox/Dockerfile`:
```dockerfile
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

WORKDIR /workspace
CMD ["sleep", "infinity"]
```

- [ ] **Step 3: Create the Justfile**

Create `~/AleCode/aoe-sandbox/Justfile`:
```makefile
# Local single-arch dev build
build:
    docker build -t aoe-sandbox:dev .

# Build with the mykb token secret (needed once Task 14 lands)
build-secret:
    docker build --secret id=mykb_token,env=MYKB_DOWNLOAD_TOKEN -t aoe-sandbox:dev .

# Multi-arch build (no push) to validate both platforms locally
build-multiarch:
    docker buildx build --platform linux/amd64,linux/arm64 -t aoe-sandbox:dev .

# Open a shell in the dev image
shell:
    docker run --rm -it aoe-sandbox:dev bash
```

- [ ] **Step 4: Create a minimal README placeholder**

Create `~/AleCode/aoe-sandbox/README.md`:
```markdown
# aoe-sandbox

Custom sandbox image for [agent-of-empires](https://github.com/njbrake/agent-of-empires).
Full usage, host prerequisites, runtime-injection config, and security posture: see Task 17 (filled in during implementation).
```

- [ ] **Step 5: Build locally and smoke-check the base**

Run:
```bash
cd ~/AleCode/aoe-sandbox && docker build -t aoe-sandbox:dev .
docker run --rm aoe-sandbox:dev bash -lc 'set -e; rg --version; jq --version; fd --version; just --version; python3 --version; java -version; R --version | head -1; locale | head -1'
```
Expected: every tool prints a version; `locale` shows `LANG=en_US.UTF-8`. No errors.

- [ ] **Step 6: Commit**

```bash
cd ~/AleCode/aoe-sandbox
git add .dockerignore Dockerfile Justfile README.md
git commit -m "feat: debian base layer with core apt deps and locale"
```

---

## Phase 2: Language toolchains

### Task 3: Go toolchain (official tarball, latest stable)

**Files:**
- Modify: `~/AleCode/aoe-sandbox/Dockerfile`

- [ ] **Step 1: Append the Go install layer (before `WORKDIR`/`CMD`)**

Insert this block immediately after the `ENV LANG=...` block and before `WORKDIR /workspace`:
```dockerfile
# Go (official tarball; apt's Go is too old for current gopls). Latest stable.
RUN set -eux; \
    GO_VERSION="$(curl -fsSL https://go.dev/VERSION?m=text | head -1)"; \
    curl -fsSL "https://go.dev/dl/${GO_VERSION}.linux-${TARGETARCH}.tar.gz" -o /tmp/go.tgz; \
    tar -C /usr/local -xzf /tmp/go.tgz; \
    rm /tmp/go.tgz
ENV PATH="/usr/local/go/bin:/root/go/bin:${PATH}"
```

- [ ] **Step 2: Build and smoke-check**

Run:
```bash
cd ~/AleCode/aoe-sandbox && docker build -t aoe-sandbox:dev .
docker run --rm aoe-sandbox:dev bash -lc 'go version'
```
Expected: `go version go1.xx.x linux/<arch>`.

- [ ] **Step 3: Commit**

```bash
git add Dockerfile && git commit -m "feat: install Go toolchain from official tarball"
```

### Task 4: Rust toolchain (rustup + rust-analyzer + clippy)

**Files:**
- Modify: `~/AleCode/aoe-sandbox/Dockerfile`

- [ ] **Step 1: Append the Rust install layer (before `WORKDIR`)**

```dockerfile
# Rust via rustup, with rust-analyzer (LSP) and clippy components.
RUN set -eux; \
    curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs | sh -s -- -y --no-modify-path \
      --component rust-analyzer clippy
ENV PATH="/root/.cargo/bin:${PATH}"
```

- [ ] **Step 2: Build and smoke-check**

Run:
```bash
cd ~/AleCode/aoe-sandbox && docker build -t aoe-sandbox:dev .
docker run --rm aoe-sandbox:dev bash -lc 'rustc --version; cargo --version; rust-analyzer --version; cargo clippy --version'
```
Expected: all four print versions.

- [ ] **Step 3: Commit**

```bash
git add Dockerfile && git commit -m "feat: install Rust toolchain with rust-analyzer and clippy"
```

### Task 5: Node.js (official tarball, latest LTS)

**Files:**
- Modify: `~/AleCode/aoe-sandbox/Dockerfile`

- [ ] **Step 1: Append the Node install layer (before `WORKDIR`)**

Node uses `x64`/`arm64` naming, so map `TARGETARCH` (`amd64`->`x64`).
```dockerfile
# Node.js LTS (official tarball). For JS/TS work, qmd (better-sqlite3), and the TS/pyright LSPs.
RUN set -eux; \
    NODE_ARCH="$(case "${TARGETARCH}" in amd64) echo x64 ;; arm64) echo arm64 ;; *) echo "unsupported ${TARGETARCH}" >&2; exit 1 ;; esac)"; \
    NODE_VERSION="$(curl -fsSL https://nodejs.org/dist/index.json | jq -r '[.[] | select(.lts != false)][0].version')"; \
    curl -fsSL "https://nodejs.org/dist/${NODE_VERSION}/node-${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz" -o /tmp/node.tar.xz; \
    tar -C /usr/local --strip-components=1 -xJf /tmp/node.tar.xz; \
    rm /tmp/node.tar.xz
```

- [ ] **Step 2: Build and smoke-check**

Run:
```bash
cd ~/AleCode/aoe-sandbox && docker build -t aoe-sandbox:dev .
docker run --rm aoe-sandbox:dev bash -lc 'node --version; npm --version; npx --version'
```
Expected: Node v22.x (or current LTS), npm, npx versions.

- [ ] **Step 3: Commit**

```bash
git add Dockerfile && git commit -m "feat: install Node.js LTS from official tarball"
```

### Task 6: Bun (official installer)

**Files:**
- Modify: `~/AleCode/aoe-sandbox/Dockerfile`

- [ ] **Step 1: Append the Bun install layer (before `WORKDIR`)**

```dockerfile
# Bun (fast JS runtime). Installer auto-detects arch.
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:${PATH}"
```

- [ ] **Step 2: Build and smoke-check**

Run:
```bash
cd ~/AleCode/aoe-sandbox && docker build -t aoe-sandbox:dev .
docker run --rm aoe-sandbox:dev bash -lc 'bun --version'
```
Expected: a Bun version string.

- [ ] **Step 3: Commit**

```bash
git add Dockerfile && git commit -m "feat: install Bun"
```

---

## Phase 3: Build/CLI tools

### Task 7: Bazel (bazelisk release binary)

**Files:**
- Modify: `~/AleCode/aoe-sandbox/Dockerfile`

- [ ] **Step 1: Append the bazelisk layer (before `WORKDIR`)**

bazelisk uses `amd64`/`arm64` naming, matching `TARGETARCH`.
```dockerfile
# Bazel via bazelisk (latest release binary).
RUN set -eux; \
    curl -fsSL "https://github.com/bazelbuild/bazelisk/releases/latest/download/bazelisk-linux-${TARGETARCH}" \
      -o /usr/local/bin/bazel; \
    chmod +x /usr/local/bin/bazel
```

- [ ] **Step 2: Build and smoke-check**

Run:
```bash
cd ~/AleCode/aoe-sandbox && docker build -t aoe-sandbox:dev .
docker run --rm aoe-sandbox:dev bash -lc 'bazel version --gnu_format 2>/dev/null || file /usr/local/bin/bazel'
```
Expected: bazelisk runs (it may print its own version without a workspace) or the file is a valid ELF executable for the arch. Either confirms the binary is present and executable.

- [ ] **Step 3: Commit**

```bash
git add Dockerfile && git commit -m "feat: install Bazel via bazelisk"
```

### Task 8: GitHub CLI (gh release tarball, latest)

**Files:**
- Modify: `~/AleCode/aoe-sandbox/Dockerfile`

- [ ] **Step 1: Append the gh layer (before `WORKDIR`)**

```dockerfile
# GitHub CLI (release tarball; avoids the apt repo + gnupg). Latest version via API.
RUN set -eux; \
    GH_VERSION="$(curl -fsSL https://api.github.com/repos/cli/cli/releases/latest | jq -r .tag_name | sed 's/^v//')"; \
    curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${TARGETARCH}.tar.gz" -o /tmp/gh.tgz; \
    tar -C /tmp -xzf /tmp/gh.tgz; \
    install -m 0755 "/tmp/gh_${GH_VERSION}_linux_${TARGETARCH}/bin/gh" /usr/local/bin/gh; \
    rm -rf /tmp/gh.tgz "/tmp/gh_${GH_VERSION}_linux_${TARGETARCH}"
```

- [ ] **Step 2: Build and smoke-check**

Run:
```bash
cd ~/AleCode/aoe-sandbox && docker build -t aoe-sandbox:dev .
docker run --rm aoe-sandbox:dev bash -lc 'gh --version'
```
Expected: `gh version x.y.z`.

- [ ] **Step 3: Commit**

```bash
git add Dockerfile && git commit -m "feat: install GitHub CLI from release tarball"
```

---

## Phase 4: Agent CLIs

### Task 9: Claude Code + OpenCode

**Files:**
- Modify: `~/AleCode/aoe-sandbox/Dockerfile`

- [ ] **Step 1: Append the agent CLI layer (before `WORKDIR`)**

```dockerfile
# Agent CLIs. Native installers auto-detect arch. No other agents, no ACP adapters (no cockpit).
RUN curl -fsSL https://claude.ai/install.sh | bash
ENV PATH="/root/.local/bin:${PATH}"
RUN curl -fsSL https://opencode.ai/install | bash
ENV PATH="/root/.opencode/bin:${PATH}"
```

- [ ] **Step 2: Build and smoke-check**

Run:
```bash
cd ~/AleCode/aoe-sandbox && docker build -t aoe-sandbox:dev .
docker run --rm aoe-sandbox:dev bash -lc 'claude --version; opencode --version'
```
Expected: both print versions. (These are offline version checks; no auth needed.)

- [ ] **Step 3: Commit**

```bash
git add Dockerfile && git commit -m "feat: install Claude Code and OpenCode CLIs"
```

---

## Phase 5: Knowledge-base + research CLIs

### Task 10: qmd (npm global)

**Files:**
- Modify: `~/AleCode/aoe-sandbox/Dockerfile`

- [ ] **Step 1: Append the qmd layer (before `WORKDIR`)**

```dockerfile
# qmd: local markdown search engine. Native better-sqlite3 build uses the
# Node + build-essential + python3 already installed.
RUN npm install -g @tobilu/qmd
```

- [ ] **Step 2: Build and smoke-check**

Run:
```bash
cd ~/AleCode/aoe-sandbox && docker build -t aoe-sandbox:dev .
docker run --rm aoe-sandbox:dev bash -lc 'qmd --version || qmd --help | head -3'
```
Expected: qmd prints a version or its help (confirms the native module compiled and the binary runs).

- [ ] **Step 3: Commit**

```bash
git add Dockerfile && git commit -m "feat: install qmd via npm"
```

### Task 11: search-cli (cargo install)

**Files:**
- Modify: `~/AleCode/aoe-sandbox/Dockerfile`

- [ ] **Step 1: Append the search-cli layer (before `WORKDIR`)**

```dockerfile
# search-cli (Rust): multi-provider search used by the deep-research skill.
# Installs the `search` binary into /root/.cargo/bin (already on PATH).
RUN cargo install agent-search
```

- [ ] **Step 2: Build and smoke-check**

Run:
```bash
cd ~/AleCode/aoe-sandbox && docker build -t aoe-sandbox:dev .
docker run --rm aoe-sandbox:dev bash -lc 'search --version || search --help | head -3'
```
Expected: prints a version or help.

- [ ] **Step 3: Commit**

```bash
git add Dockerfile && git commit -m "feat: install search-cli via cargo"
```

### Task 12: deep-research runtime deps (WeasyPrint system libs + package)

**Files:**
- Modify: `~/AleCode/aoe-sandbox/Dockerfile`

The deep-research **skill** itself is host-side (synced by aoe from `~/.claude/skills`); only its out-of-`.claude` runtime deps belong in the image.

- [ ] **Step 1: Append the WeasyPrint layer (before `WORKDIR`)**

```dockerfile
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
```

- [ ] **Step 2: Build and smoke-check**

Run:
```bash
cd ~/AleCode/aoe-sandbox && docker build -t aoe-sandbox:dev .
docker run --rm aoe-sandbox:dev bash -lc 'python3 -c "import weasyprint; print(weasyprint.__version__)"'
```
Expected: a WeasyPrint version string with no import errors (confirms native libs are present).

- [ ] **Step 3: Commit**

```bash
git add Dockerfile && git commit -m "feat: install WeasyPrint and native libs for deep-research PDF export"
```

---

## Phase 6: Runtime dirs + first CI publish (so mykb download has a place to land)

### Task 13: Credential-mount dirs + PATH finalize

**Files:**
- Modify: `~/AleCode/aoe-sandbox/Dockerfile`

- [ ] **Step 1: Append the dirs layer (immediately before `WORKDIR /workspace`)**

```dockerfile
# Pre-create the credential-mount dirs aoe bind-mounts at runtime.
RUN mkdir -p \
    /root/.claude \
    /root/.config/opencode \
    /root/.local/share/opencode \
    /root/.ssh
```

- [ ] **Step 2: Build and smoke-check**

Run:
```bash
cd ~/AleCode/aoe-sandbox && docker build -t aoe-sandbox:dev .
docker run --rm aoe-sandbox:dev bash -lc 'ls -ld /root/.claude /root/.config/opencode /root/.local/share/opencode /root/.ssh /workspace'
```
Expected: all five directories exist.

- [ ] **Step 3: Commit**

```bash
git add Dockerfile && git commit -m "feat: pre-create credential-mount directories"
```

### Task 14: mykb CLI (download Release asset via build secret)

**Depends on:** Phase 0 (Task 1) having published `mykb-linux-{amd64,arm64}` on `alepar/mykb`.

**Files:**
- Modify: `~/AleCode/aoe-sandbox/Dockerfile`

- [ ] **Step 1: Append the mykb layer (before the dirs layer / `WORKDIR`)**

```dockerfile
# mykb CLI: download the latest Release asset from private alepar/mykb.
# Token is provided as a BuildKit secret (never persisted in a layer).
RUN --mount=type=secret,id=mykb_token \
    set -eux; \
    TOKEN="$(cat /run/secrets/mykb_token)"; \
    API="https://api.github.com/repos/alepar/mykb/releases/latest"; \
    ASSET_URL="$(curl -fsSL -H "Authorization: Bearer ${TOKEN}" "${API}" \
      | jq -r ".assets[] | select(.name==\"mykb-linux-${TARGETARCH}\") | .url")"; \
    test -n "${ASSET_URL}"; \
    curl -fsSL -H "Authorization: Bearer ${TOKEN}" -H "Accept: application/octet-stream" \
      "${ASSET_URL}" -o /usr/local/bin/mykb; \
    chmod +x /usr/local/bin/mykb
```

- [ ] **Step 2: Build with the secret and smoke-check**

Run (requires a PAT with read access to `alepar/mykb` in `MYKB_DOWNLOAD_TOKEN`):
```bash
cd ~/AleCode/aoe-sandbox
export MYKB_DOWNLOAD_TOKEN=<your-PAT>
docker build --secret id=mykb_token,env=MYKB_DOWNLOAD_TOKEN -t aoe-sandbox:dev .
docker run --rm aoe-sandbox:dev bash -lc 'mykb --version || mykb --help | head -3'
```
Expected: `mykb` prints a version or help. If the asset URL is empty, Phase 0 has not published the release yet.

- [ ] **Step 3: Commit**

```bash
git add Dockerfile && git commit -m "feat: download mykb CLI from private release via build secret"
```

### Task 15: CI workflow (multi-arch buildx -> GHCR)

**Files:**
- Create: `~/AleCode/aoe-sandbox/.github/workflows/build.yml`

- [ ] **Step 1: Write the build/publish workflow**

Create `~/AleCode/aoe-sandbox/.github/workflows/build.yml`:
```yaml
name: Build and Push

on:
  push:
    branches: [main]
    tags: ['v*']
  workflow_dispatch:

env:
  IMAGE: ghcr.io/alepar/aoe-sandbox

jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    steps:
      - uses: actions/checkout@v4

      - uses: docker/setup-qemu-action@v3

      - uses: docker/setup-buildx-action@v3

      - name: Log in to GHCR
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Metadata
        id: meta
        uses: docker/metadata-action@v5
        with:
          images: ${{ env.IMAGE }}
          tags: |
            type=raw,value=latest,enable=${{ github.ref == 'refs/heads/main' }}
            type=sha,prefix=sha-
            type=semver,pattern={{version}}

      - name: Build and push (multi-arch)
        uses: docker/build-push-action@v6
        with:
          context: .
          platforms: linux/amd64,linux/arm64
          push: true
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
          secrets: |
            mykb_token=${{ secrets.MYKB_DOWNLOAD_TOKEN }}
```

- [ ] **Step 2: Add the `MYKB_DOWNLOAD_TOKEN` repo secret**

Run (after the GitHub repo `alepar/aoe-sandbox` exists; see Task 18):
```bash
gh secret set MYKB_DOWNLOAD_TOKEN --repo alepar/aoe-sandbox --body "<PAT-with-read-access-to-alepar/mykb>"
```
Expected: `✓ Set secret MYKB_DOWNLOAD_TOKEN`.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/build.yml && git commit -m "ci: multi-arch buildx publish to GHCR with mykb build secret"
```

---

## Phase 7: Language servers (LAST, per design)

### Task 16: gopls + clangd + jdtls + pyright (rust-analyzer already from Task 4)

**Files:**
- Modify: `~/AleCode/aoe-sandbox/Dockerfile`

- [ ] **Step 1: Append the LSP layer (before the credential-dirs layer / `WORKDIR`)**

```dockerfile
# Language servers (installed last). rust-analyzer came with the Rust toolchain.
# clangd (C/C++) via apt; gopls via go install; pyright (Python) via npm.
RUN apt-get update && apt-get install -y --no-install-recommends clangd \
 && rm -rf /var/lib/apt/lists/* \
 && go install golang.org/x/tools/gopls@latest \
 && npm install -g pyright

# jdtls (Eclipse JDT Language Server) -> /opt/jdtls, launcher on PATH (uses default-jdk).
RUN set -eux; \
    mkdir -p /opt/jdtls; \
    curl -fsSL https://download.eclipse.org/jdtls/snapshots/jdt-language-server-latest.tar.gz -o /tmp/jdtls.tgz; \
    tar -C /opt/jdtls -xzf /tmp/jdtls.tgz; \
    rm /tmp/jdtls.tgz; \
    printf '#!/bin/sh\nexec java -jar /opt/jdtls/plugins/org.eclipse.equinox.launcher_*.jar "$@"\n' > /usr/local/bin/jdtls; \
    chmod +x /usr/local/bin/jdtls
```

- [ ] **Step 2: Build and smoke-check each LSP**

Run:
```bash
cd ~/AleCode/aoe-sandbox
docker build --secret id=mykb_token,env=MYKB_DOWNLOAD_TOKEN -t aoe-sandbox:dev .
docker run --rm aoe-sandbox:dev bash -lc 'gopls version; clangd --version; pyright --version; rust-analyzer --version; ls /opt/jdtls/plugins/org.eclipse.equinox.launcher_*.jar'
```
Expected: gopls, clangd, pyright, rust-analyzer versions print; the jdtls launcher jar path resolves to exactly one file.

- [ ] **Step 3: Commit**

```bash
git add Dockerfile && git commit -m "feat: install gopls, clangd, pyright, and jdtls language servers"
```

---

## Phase 8: Docs + repo publish + end-to-end verification

### Task 17: Full README (usage, host prerequisites, runtime injection, security posture)

**Files:**
- Modify: `~/AleCode/aoe-sandbox/README.md`

- [ ] **Step 1: Replace the README placeholder with full content**

```markdown
# aoe-sandbox

Custom multi-arch (amd64 + arm64) sandbox image for [agent-of-empires](https://github.com/njbrake/agent-of-empires).

Ships: Claude Code + OpenCode; Go/Rust/Node/Bun/Python/Java/R toolchains; gopls, rust-analyzer, clangd, jdtls, pyright; bazel, gh, just, fd, ripgrep, jq, cmake; qmd, mykb, search-cli.

## Use with aoe

```toml
# ~/.config/agent-of-empires/config.toml (Linux) or ~/.agent-of-empires/config.toml (macOS)
[sandbox]
container_runtime = "podman"
default_image = "ghcr.io/alepar/aoe-sandbox:latest"
extra_volumes = ["/host/path/to/qmd-corpus:/root/qmd:ro"]
environment = [
    "GH_TOKEN=$GH_TOKEN",
    "MYKB_API_URL=$MYKB_API_URL",
    "VOYAGE_API_KEY=$VOYAGE_API_KEY",
    "MEILISEARCH_KEY=$MEILISEARCH_KEY",
    "SEARCH_KEYS_BRAVE=$SEARCH_KEYS_BRAVE",
]
```

## Host prerequisites (synced into the sandbox by aoe, not baked)

aoe copies your `~/.claude/plugins` and `~/.claude/skills` into every sandbox, so install these on the host:

- **superpowers plugin** (already installed if you use it).
- **deep-research skill**: `git clone https://github.com/199-biotechnologies/claude-deep-research-skill ~/.claude/skills/deep-research`

## Security posture (Linux)

This image runs as root inside the container (required: aoe hardcodes `/root` as the container home). Run it under **rootless Podman** so container-root maps to your unprivileged host user, not host root:

```sh
podman info | grep -iA2 rootless          # expect: rootless: true
podman run --rm ghcr.io/alepar/aoe-sandbox:latest cat /proc/self/uid_map   # expect: 0 <your-uid> 1
```

Run `aoe` as your normal user (never `sudo`). On rootful Docker, container-root == host root on a breakout; prefer rootless Podman (or rootless Docker / userns-remap).

## Build locally

```sh
just build                 # single-arch dev build
just build-multiarch       # validate both platforms
```
mykb requires a `MYKB_DOWNLOAD_TOKEN` env var (PAT with read access to `alepar/mykb`): `just build-secret`.
```

- [ ] **Step 2: Commit**

```bash
git add README.md && git commit -m "docs: full README with usage, prerequisites, and security posture"
```

### Task 18: Create the GitHub repo and push

**Files:** none (repo operation)

- [ ] **Step 1: Create the remote repo and push**

Run (in `~/AleCode/aoe-sandbox`):
```bash
gh repo create alepar/aoe-sandbox --private --source=. --remote=origin --push
```
Expected: repo created, `main` pushed.

- [ ] **Step 2: Set the build secret (if not already done in Task 15)**

```bash
gh secret set MYKB_DOWNLOAD_TOKEN --repo alepar/aoe-sandbox --body "<PAT-with-read-access-to-alepar/mykb>"
```

- [ ] **Step 3: Verify CI publishes the image**

Run:
```bash
gh run watch --repo alepar/aoe-sandbox
```
Expected: the "Build and Push" workflow succeeds and pushes `ghcr.io/alepar/aoe-sandbox:latest` (multi-arch). Confirm with:
```bash
docker manifest inspect ghcr.io/alepar/aoe-sandbox:latest | jq '.manifests[].platform'
```
Expected: both `linux/amd64` and `linux/arm64` present.

### Task 19: End-to-end verification with aoe

**Files:** none (manual validation)

- [ ] **Step 1: Point aoe at the image and launch a sandboxed session**

Set `default_image = "ghcr.io/alepar/aoe-sandbox:latest"` and `container_runtime = "podman"` in your aoe config (see README), then:
```bash
aoe add --sandbox .
```

- [ ] **Step 2: Confirm tools + synced skills/plugins inside the session**

In the session's container terminal:
```bash
claude --version && opencode --version && qmd --version && mykb --version && search --version
ls /root/.claude/skills/deep-research        # synced from host
ls /root/.claude/plugins/marketplaces        # superpowers etc. synced from host
cat /proc/self/uid_map                        # rootless Podman: 0 <your-uid> 1
```
Expected: all tools report versions; deep-research skill + plugin marketplaces are present (synced by aoe); uid_map confirms container-root maps to your host user.

- [ ] **Step 3: Final commit (any doc tweaks discovered during E2E)**

```bash
git add -A && git commit -m "docs: e2e verification notes" || echo "nothing to commit"
```

---

## Self-Review

**Spec coverage:**
- Base/debian/multi-arch/single-stage/root -> Task 2 + Task 15 (multi-arch CI). ✓
- apt set (no gnupg/fzf, fd symlink, locale) -> Task 2. ✓
- Languages Python/Java/R (apt) -> Task 2; Go/Rust/Node/Bun -> Tasks 3-6. ✓
- Build/CLI tools cmake/just/fd (Task 2), bazel (7), gh (8). ✓
- Agent CLIs Claude+OpenCode, no ACP adapters -> Task 9. ✓
- qmd (10), search-cli (11), mykb (14 + Phase 0). ✓
- deep-research runtime deps (WeasyPrint) -> Task 12; skill itself host-side -> README Task 17. ✓
- superpowers host-side -> README Task 17. ✓
- LSPs last (gopls/rust-analyzer/clangd/jdtls/pyright) -> Task 16. ✓
- Runtime env/dirs/workdir/cmd -> Task 2 (env/workdir/cmd) + Task 13 (dirs). ✓
- Security posture + verify commands -> README Task 17 + Task 19. ✓
- Runtime injection contract -> README Task 17. ✓
- CI to GHCR + build secret -> Task 15; repo create -> Task 18. ✓
- Phase 0 mykb release workflow -> Task 1. ✓

**Placeholder scan:** `<your-PAT>` / `<your-uid>` / `<PAT-with-read-access...>` are user-supplied secrets/values, not plan placeholders. No TBD/TODO in implementation steps. ✓

**Type/name consistency:** secret id `mykb_token` is consistent across Dockerfile (Tasks 14, 16), Justfile (Task 2), and CI (Task 15). Asset name `mykb-linux-${TARGETARCH}` matches Phase 0's `mykb-linux-${{ matrix.arch }}`. PATH additions are cumulative and non-conflicting. ✓

**Note on layer ordering:** tasks append in cheap->expensive order; the mykb secret layer (Task 14) and LSP layer (Task 16) are appended near the end so earlier cached layers are reused across the frequent rebuilds. The exact in-file position ("before WORKDIR") keeps `WORKDIR`/`CMD` as the final instructions.
```
