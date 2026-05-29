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
    # Node.js (needed for Claude Code)
    nodejs \
    npm \
    # Build tools
    build-essential \
    cmake \
    ninja-build \
    pkg-config \
    flex \
    bison \
    python3 \
    # tshark dependencies
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

# Replace the nodejs/npm apt install with:
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs \
    && apt-get clean && rm -rf /var/lib/apt/lists/*    
     
# Create node user (not present in plain debian:bookworm)
RUN useradd -m -u 1000 -s /bin/bash node \
    && echo "node ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

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

ARG CLAUDE_CODE_VERSION=latest
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}

ENV DEVCONTAINER=true
ENV EDITOR=nano
ENV VISUAL=nano
ENV SHELL=/bin/bash