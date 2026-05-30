# aoe-sandbox

Custom multi-arch (amd64 + arm64) Debian sandbox image for [agent-of-empires](https://github.com/njbrake/agent-of-empires) (aoe).

**Ships:**
- **Agents:** Claude Code, OpenCode (tmux-mode only; no cockpit/ACP adapters).
- **Toolchains:** Go, Rust, Node.js (LTS), Bun, Python 3, Java (JDK 21), R.
- **Language servers:** gopls, rust-analyzer, clangd, jdtls, pyright.
- **Dev tools:** bazel (bazelisk), gh, just, fd, ripgrep, jq, cmake.
- **Knowledge/research:** qmd, mykb, search-cli.

The image ships **system binaries and toolchains only**. Claude config (plugins, skills, credentials) is delivered at runtime by aoe's credential-sync, not baked in (see Host prerequisites).

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

qmd's corpus/index is mounted via `extra_volumes`; mykb's endpoint + keys and search-cli's provider keys (`SEARCH_KEYS_*`) are forwarded via `environment`. None of this data is baked into the image.

## Host prerequisites (synced into the sandbox by aoe, not baked)

aoe copies your `~/.claude/plugins` and `~/.claude/skills` into every sandbox, so install these on the host once:

- **superpowers plugin** (already present if you use it).
- **deep-research skill:**
  ```sh
  git clone https://github.com/199-biotechnologies/claude-deep-research-skill ~/.claude/skills/deep-research
  ```
  Its runtime deps (Python, WeasyPrint, search-cli) are in the image; the skill itself comes from the host. search-cli falls back to aoe/Claude's built-in WebSearch if no `SEARCH_KEYS_*` provider key is set.

## Security posture (Linux)

The image runs as **root** inside the container (required: aoe hardcodes `/root` as the container home). Run it under **rootless Podman** so container-root maps to your unprivileged host user, not host root:

```sh
podman info | grep -iA2 rootless          # expect: rootless: true
podman run --rm ghcr.io/alepar/aoe-sandbox:latest cat /proc/self/uid_map   # expect: 0 <your-uid> 1
```

Run `aoe` as your normal user (never `sudo`). On rootful Docker, container-root == host root on a breakout; prefer rootless Podman (or rootless Docker / Docker userns-remap).

## Build locally

```sh
just build                 # single-arch dev build
just build-multiarch       # validate both platforms (no push)
```

## Notes

- **search-cli** is installed from the [`alepar/search-cli`](https://github.com/alepar/search-cli) fork, which switches `self_update`/`readability` to rustls (resolving an OpenSSL/BoringSSL link conflict that breaks the upstream crate on Linux) and migrates the yanked `rquest` dependency to the maintained `wreq`.
- **mykb** is downloaded from a release of the private `alepar/mykb` repo at build time (CI uses a `MYKB_DOWNLOAD_TOKEN` build secret).
