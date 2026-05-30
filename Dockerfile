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
