# Local single-arch dev build
build:
    docker build -t aoe-sandbox:dev .

# Build with the mykb token secret (needed once the mykb layer lands)
build-secret:
    docker build --secret id=mykb_token,env=MYKB_DOWNLOAD_TOKEN -t aoe-sandbox:dev .

# Multi-arch build (no push) to validate both platforms locally
build-multiarch:
    docker buildx build --platform linux/amd64,linux/arm64 -t aoe-sandbox:dev .

# Open a shell in the dev image
shell:
    docker run --rm -it aoe-sandbox:dev bash
