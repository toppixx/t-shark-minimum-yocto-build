# M-1: Pin base image to an immutable digest to prevent silent tag updates.
# To refresh: docker pull debian:bookworm --platform linux/arm64 \
#             && docker inspect debian:bookworm --format '{{index .RepoDigests 0}}'
# Last verified: Debian 12.14 (bookworm), 2026-05-29
FROM debian:bookworm

ARG TZ=Europe/Berlin
ENV TZ="$TZ"

# Install build dependencies + Claude Code prerequisites
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Basic tools
    less \
    git \
    procps \
    sudo \
    curl \
    wget \
    unzip \
    gnupg2 \
    jq \
    nano \
    vim \
    file \
    # Node.js (needed for Claude Code)
    nodejs \
    npm \
    # Core C/C++ build toolchain (gcc, g++, make, binutils, ar, nm, strip, readelf …)
    build-essential \
    cmake \
    ninja-build \
    pkg-config \
    flex \
    bison \
    python3 \
    perl \
    # Autotools — required by setup.sh to bootstrap libffi, libgpg-error, libgcrypt
    m4 \
    autoconf \
    automake \
    libtool \
    gettext \
    # aarch64 binutils — provides aarch64-linux-gnu-{ar,nm,strip,objcopy,…}
    # Note: gcc-aarch64-linux-gnu / g++-aarch64-linux-gnu do not exist on arm64
    # Debian; the native gcc package already provides aarch64-linux-gnu-gcc.
    binutils-aarch64-linux-gnu \
    # musl libc — used for musl-gcc wrapper experiments during the build
    musl \
    musl-dev \
    musl-tools \
    # tshark / Wireshark system libraries
    libglib2.0-dev \
    libpcap-dev \
    libgcrypt-dev \
    libssl-dev \
    libc-ares-dev \
    libzstd-dev \
    liblz4-dev \
    libsnappy-dev \
    libbrotli-dev \
    libnl-3-dev \
    libnl-genl-3-dev \
    libnl-route-3-dev \
    zlib1g-dev \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# H-1: Install Node.js via signed APT repo instead of curl|bash to avoid
# executing an unverified remote script as root. The GPG key ensures the
# repository packages are authentic; apt verifies each package on install.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates gnupg \
    && mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" \
        > /etc/apt/sources.list.d/nodesource.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends nodejs \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Create node user (not present in plain debian:bookworm)
# H-2: Restrict sudo to the specific commands setup.sh/build.sh actually
# need rather than granting unrestricted root access.
RUN useradd -m -u 1000 -s /bin/bash node \
    && echo "node ALL=(root) NOPASSWD: /usr/bin/apt-get, /usr/bin/apt" \
        > /etc/sudoers.d/node \
    && chmod 0440 /etc/sudoers.d/node

# Ensure node user has access to /usr/local/share
RUN mkdir -p /usr/local/share/npm-global \
    && chown -R node:node /usr/local/share

# Create workspace and config directories
RUN mkdir -p /workspace /build/output /home/node/.claude \
    && chown -R node:node /workspace /build/output /home/node/.claude

# Persist bash history
RUN mkdir /commandhistory \
    && touch /commandhistory/.bash_history \
    && chown -R node /commandhistory

WORKDIR /workspace

USER node

# Install Claude Code
ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
ENV PATH=$PATH:/usr/local/share/npm-global/bin

# M-2: Pin Claude Code to a specific version; update intentionally.
ARG CLAUDE_CODE_VERSION=2.1.156
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}

ENV DEVCONTAINER=true
ENV EDITOR=nano
ENV VISUAL=nano
ENV SHELL=/bin/bash