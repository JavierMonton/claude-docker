# Sandbox image for running Claude Code in a disposable Docker container.
# The container is the security boundary: Claude runs as the non-root `node` user and
# only sees the folder you bind-mount in. Nothing is installed on the host. By default
# Claude runs with its normal approval prompts; pass --dangerously-skip-permissions to
# run it in fully autonomous YOLO mode.
FROM node:22-bookworm

# --- System tools Claude commonly needs -------------------------------------
# Includes search/build tooling, Python, and gosu (for the privilege drop in the
# entrypoint). Network egress is left open so Claude can pip/npm/uv/apt install freely.
RUN apt-get update && apt-get install -y --no-install-recommends \
        git \
        curl \
        wget \
        ca-certificates \
        ripgrep \
        fd-find \
        jq \
        build-essential \
        python3 \
        python3-pip \
        python3-venv \
        pipx \
        vim \
        nano \
        less \
        sudo \
        gnupg2 \
        openssh-client \
        unzip \
        gosu \
    && rm -rf /var/lib/apt/lists/*

# uv (fast Python package/venv manager) via the official standalone installer.
RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh

# Claude Code CLI. Installs the latest release; the CLI then auto-updates itself at
# runtime, so the cached image stays current without rebuilds.
RUN npm install -g @anthropic-ai/claude-code

# Passwordless sudo for the disposable, isolated `node` user (uid/gid 1000 in this image).
RUN echo 'node ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/node \
    && chmod 0440 /etc/sudoers.d/node

ENV DEVCONTAINER=true \
    CLAUDE_CONFIG_DIR=/home/node/.claude \
    EDITOR=nano

# Ensure the config dir exists so the named volume mounts cleanly and is owned by node.
RUN mkdir -p /home/node/.claude && chown -R node:node /home/node/.claude

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

WORKDIR /workspace
ENTRYPOINT ["docker-entrypoint.sh"]
