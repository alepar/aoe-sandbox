# Local single-arch dev build
build:
    docker build -t aoe-sandbox:dev .

# Optional: build passing a GitHub token to raise the API rate limit for the
# mykb release download. Not required (alepar/mykb is public); plain `build` works.
build-token:
    MYKB_TOKEN=$(gh auth token) docker build --secret id=mykb_token,env=MYKB_TOKEN -t aoe-sandbox:dev .

# Multi-arch build (no push) to validate both platforms locally
build-multiarch:
    docker buildx build --platform linux/amd64,linux/arm64 -t aoe-sandbox:dev .

# Open a shell in the dev image
shell:
    docker run --rm -it aoe-sandbox:dev bash
