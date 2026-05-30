# Custom aoe-sandbox Image - Design

Date: 2026-05-30
Repo: `github.com/alepar/aoe-sandbox` (new)
Status: design approved, pending spec review

## Goal

A personal, custom Docker/Podman sandbox image for [agent-of-empires](https://github.com/njbrake/agent-of-empires) (aoe) sessions, derived from aoe's default `aoe-sandbox` image but tailored: Debian base, only the agents and tools we use, our knowledge-base CLIs, and preinstalled language toolchains + LSPs.

The image ships **system-level binaries and toolchains only**. Claude config (plugins, skills, credentials) is delivered at runtime by aoe's existing credential-sync, not baked in (see "What is intentionally NOT in the image").

## Key decisions (resolved during brainstorming)

| Decision | Choice | Rationale |
|---|---|---|
| Base image | `debian:stable` | Requested; trixie/Debian 13 at time of writing. |
| Architecture | multi-arch `linux/amd64` + `linux/arm64` via `docker buildx` | Run on both Apple Silicon and remote x86 hosts. |
| Dockerfile structure | single-stage, layered cheap->expensive | Dev sandbox needs the full toolchains at runtime; little to strip in a multi-stage build. The base/full split (aoe-style) is a documented future option if size bites. |
| Container user | **root**, `HOME=/root`, `IS_SANDBOX=1` | aoe hardcodes `CONTAINER_HOME = "/root"` for all credential sync, `CLAUDE_CONFIG_DIR`, and plugin/skill paths (`src/session/container_config.rs`). Matching it is effectively mandatory. `IS_SANDBOX=1` un-blocks Claude's `--dangerously-skip-permissions` under root. |
| Cockpit support | **none** | tmux-mode only. Drops Node-as-ACP-host and all ACP adapters. Keeps inference on the interactive subscription budget (tmux runs the official `claude` CLI; cockpit's ACP/Agent-SDK path spends the separate Agent SDK credit pool). |
| Agent CLIs | Claude Code + OpenCode only | The only two we use. |
| Homebrew | **skipped** | Everything installs via apt/cargo/native; brew fights the root requirement and is tier-2 on arm64 Linux. Clean opt-in later (non-root `linuxbrew` user). |

## Runtime security posture (Linux)

aoe invokes `podman`/`docker` as the user running `aoe`, passing **no** `--user`/`--userns` flags (`runtime_base.rs` argv: `run -d --name -w -v -e -p --cpus -m <image> sleep infinity`; no `--cap-drop`, `--security-opt`, `--read-only`, or network restriction). The host mapping is therefore whatever the runtime defaults to:

- **Rootless Podman (recommended):** container UID 0 maps to **your host user** (single default `uid_map` entry); container UIDs 1+ map to your `/etc/subuid` range. So container-root == you, not host-root. `/root` + writable project mount work ergonomically *and* safely. A breakout lands as your unprivileged host UID.
- **Rootful Docker (default Docker Engine):** container UID 0 == host UID 0. Convenient but a breakout is host-root-equivalent. Avoid for this workload.

Recommendation baked into the README: on Linux, run under **rootless Podman** (`container_runtime = "podman"` in aoe config) and run `aoe` as your normal user (never `sudo`). Verify with:

```sh
podman info | grep -iA2 rootless                       # rootless: true
podman run --rm <image> cat /proc/self/uid_map         # expect: 0 <your-uid> 1
```

macOS note: a Podman-machine Linux VM sits in between, so the clean "container-root == my host user" mapping is the Linux-host case. macOS file sharing handles ownership through the VM.

## Image contents

### Base + apt (single layer, `--no-install-recommends`, clean lists)

`curl git ca-certificates ripgrep openssh-client unzip jq build-essential cmake locales fd-find just clang clangd python3 python3-pip python3-venv default-jdk r-base`

Then `locale-gen en_US.UTF-8`. Dropped vs aoe's image: `gnupg` (no apt-key dance needed; `gh` comes from a tarball), `fzf` (cosmetic), Node-22-from-NodeSource (replaced by official tarball below). `fd-find` ships the binary as `fdfind`; symlink to `fd`.

### Language toolchains

| Language | Source | Notes |
|---|---|---|
| Python | apt `python3` + pip + venv | |
| Java | apt `default-jdk` | JDK 21 on trixie; also satisfies jdtls. |
| R | apt `r-base` | |
| C/C++ | apt `build-essential` + `clang`/`clangd` | |
| Go | official tarball -> `/usr/local/go` | apt Go too old for current gopls; arch-detected. |
| Rust | rustup (`-y`) -> `/root/.cargo/bin` | + `rust-analyzer`, `clippy` components. |
| Node (JS/TS) | official Node LTS tarball | Re-added for JS/TS work + qmd (better-sqlite3) + TS LSP. Tarball avoids re-adding gnupg. |
| Bun | official `bun.sh/install` -> `/root/.bun/bin` | |

### Build / CLI tools

- `cmake` (apt), `just` (apt), `fd` (apt `fd-find` + symlink).
- **bazel**: bazelisk release binary, arch-detected -> `/usr/local/bin/bazel`.
- **gh** (GitHub CLI): release tarball, arch-detected -> `/usr/local/bin/gh`. Pairs with aoe's `GH_TOKEN` credential-helper flow.

### Agent CLIs

- Claude Code: `curl -fsSL https://claude.ai/install.sh | bash` -> `/root/.local/bin`.
- OpenCode: `curl -fsSL https://opencode.ai/install | bash` -> `/root/.opencode/bin`.

No other agents; no ACP adapters (no cockpit).

### Knowledge-base + research CLIs

- **qmd**: `npm install -g @tobilu/qmd` (native better-sqlite3 build uses the Node + build-essential + python3 already present).
- **mykb**: download prebuilt multi-arch release binary from **private** `alepar/mykb` -> `/usr/local/bin/mykb`. CI passes a PAT build secret (`MYKB_DOWNLOAD_TOKEN`); the token never lands in an image layer.
- **search-cli**: `cargo install agent-search` (Rust; binary `search`). Used by the deep-research skill; the skill falls back to aoe/Claude's built-in WebSearch if no provider key is configured.

### Language servers (LSPs) - implemented LAST

| Language | LSP | Source |
|---|---|---|
| Go | gopls | `go install golang.org/x/tools/gopls@latest` -> `/root/go/bin` |
| Rust | rust-analyzer | rustup component (from toolchains) |
| C/C++ | clangd | apt `clangd` |
| Java | jdtls | Eclipse JDT LS release tarball -> `/opt/jdtls` + launcher on PATH (uses JDK 21) |
| Python | pyright (npm; Node present) or `python-lsp-server` (pure-Python) | finalize when building this section |

### Deep-research runtime deps (skill itself lives on the host, see below)

- Python (present) + **WeasyPrint** (`pip install weasyprint`) for PDF export. WeasyPrint pulls cairo/pango/gdk-pixbuf; it is the first thing to cut if image size is a problem.
- search-cli (above).

### Runtime env + entrypoint

- `ENV IS_SANDBOX=1`, `LANG=en_US.UTF-8`.
- Consolidated `PATH`: `/root/.local/bin:/root/.opencode/bin:/root/.cargo/bin:/usr/local/go/bin:/root/go/bin:/root/.bun/bin:${PATH}`.
- Pre-create credential-mount dirs: `/root/.claude`, `/root/.config/opencode`, `/root/.local/share/opencode`, `/root/.ssh`.
- `WORKDIR /workspace`, `CMD ["sleep", "infinity"]`.

## What is intentionally NOT in the image (host-side, synced by aoe)

aoe's `claude` config mount has `copy_dirs: ["plugins", "skills"]` and bind-mounts the assembled `.claude` dir over `/root/.claude` (a whole-directory mount). Anything baked under `/root/.claude` is **shadowed at runtime**. Therefore:

- **superpowers plugin (preinstalled):** already in your host `~/.claude/plugins`; aoe syncs it into every sandbox automatically. No image work. Brainstorming and the rest are available out of the box.
- **deep-research skill:** install once on the host (`git clone https://github.com/199-biotechnologies/claude-deep-research-skill ~/.claude/skills/deep-research`); aoe syncs it in. The image only provides its out-of-`.claude` runtime deps (Python, WeasyPrint, search-cli).

Host prerequisites documented in the README.

## Runtime injection contract (aoe config, not the image)

KB data and secrets are provided at session time via aoe's existing mechanisms, never baked (repo may be public):

```toml
[sandbox]
container_runtime = "podman"
default_image = "ghcr.io/alepar/aoe-sandbox:latest"
extra_volumes = ["/host/path/to/qmd-corpus:/root/qmd:ro"]
environment = [
    "GH_TOKEN=$GH_TOKEN",
    "MYKB_API_URL=$MYKB_API_URL",        # exact mykb-client env vars TBD vs the CLI
    "VOYAGE_API_KEY=$VOYAGE_API_KEY",
    "MEILISEARCH_KEY=$MEILISEARCH_KEY",
    "SEARCH_KEYS_BRAVE=$SEARCH_KEYS_BRAVE",   # or other search-cli providers
]
```

## Repo layout + CI

```
aoe-sandbox/
  Dockerfile
  README.md            # usage, host prerequisites, runtime-injection config, security posture
  Justfile             # local `docker buildx build` convenience
  .github/workflows/build.yml
  docs/superpowers/specs/2026-05-30-custom-aoe-sandbox-image-design.md
```

CI (`build.yml`): `docker/setup-qemu-action` + `setup-buildx-action`, login to GHCR with the built-in `GITHUB_TOKEN`, `docker buildx build --platform linux/amd64,linux/arm64 --push` to `ghcr.io/alepar/aoe-sandbox:latest` and `:sha-<short>`. Triggers: push to `main` and version tags. `MYKB_DOWNLOAD_TOKEN` repo secret passed as a buildx secret for the mykb release download.

## Prerequisites / assumptions / risks

1. **`alepar/mykb` must publish multi-arch Linux release binaries** (amd64 + arm64). It is a private repo, so CI needs `MYKB_DOWNLOAD_TOKEN` (PAT with read access). If releases do not exist yet, that is a blocking prerequisite.
2. **mykb client runtime config** (endpoint + auth env var names) to be confirmed against the `mykb` CLI when wiring it.
3. **Host prerequisites** for the synced Claude config: superpowers plugin installed, deep-research skill cloned into `~/.claude/skills`.
4. **Image will be large** (~3-5 GB+): JDK + jdtls, Rust, Go, Node, Bun, R, and five LSPs. Inherent to scope; base/full split is the escape hatch.
5. **Root-in-container is safe only under rootless Podman** (or rootless Docker). Rootful Docker gives host-root on breakout; documented, not prevented by the image.

## Out of scope (possible follow-ups)

- A non-root (`-nonroot`, `ARG UID`) image variant for users pinned to rootful Docker.
- A lean base/full two-tag split.
- Upstream aoe hardening (emit `--cap-drop=ALL --security-opt=no-new-privileges`, optional non-root container user).
- Homebrew under a dedicated non-root user.

## Build sequence (for the implementation plan)

1. Repo scaffold: `Dockerfile` skeleton (debian:stable, apt layer, env, workdir, cmd) + `README` + `Justfile`.
2. Language toolchains (Go, Rust, Node, Bun; Python/Java/R via apt).
3. Build/CLI tools (bazel, gh, just, fd).
4. Agent CLIs (Claude Code, OpenCode).
5. KB/research CLIs (qmd, search-cli; mykb via PAT secret).
6. CI workflow (multi-arch buildx -> GHCR) + first published image.
7. **LSPs last** (gopls, rust-analyzer, clangd, jdtls, Python LSP).
8. README: host prerequisites, runtime-injection config, rootless-Podman security posture + verify commands.
