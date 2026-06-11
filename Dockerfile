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
        zip \
        gosu \
    && rm -rf /var/lib/apt/lists/*

# uv (fast Python package/venv manager) via the official standalone installer.
RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh

# SDKMAN — per-user manager for JVM tooling. Lets future sessions `sdk install` any version
# of Java, Scala, Kotlin, Maven, Gradle, sbt, etc. at runtime without rebuilding the image.
# SDKMAN is per-user, so it's installed for the non-root `node` user under $SDKMAN_DIR (which
# the installer honors over $HOME). rcupdate=false stops it from editing root's shell files;
# we wire it into node's rc files ourselves so the `sdk` function and installed tool shims are
# on PATH however the shell starts. We edit the config to auto-answer `sdk install` prompts (so
# non-interactive agent sessions don't hang on a y/n) and to skip the per-shell self-update
# check. The init snippet is written to BOTH .bashrc and .bash_profile (rather than chaining
# them) so it loads regardless of shell type, bypassing the usual non-interactive .bashrc guard.
ENV SDKMAN_DIR=/home/node/.sdkman
RUN curl -s "https://get.sdkman.io?rcupdate=false" | bash \
    && sed -i \
        -e 's/^sdkman_auto_answer=.*/sdkman_auto_answer=true/' \
        -e 's/^sdkman_auto_selfupdate=.*/sdkman_auto_selfupdate=false/' \
        "$SDKMAN_DIR/etc/config" \
    && printf '\n# SDKMAN\nexport SDKMAN_DIR="%s"\n[[ -s "$SDKMAN_DIR/bin/sdkman-init.sh" ]] && source "$SDKMAN_DIR/bin/sdkman-init.sh"\n' "$SDKMAN_DIR" \
        | tee -a /home/node/.bashrc /home/node/.bash_profile > /dev/null \
    && chown -R node:node "$SDKMAN_DIR" /home/node/.bashrc /home/node/.bash_profile

# Install global npm packages into the node user's home rather than the root-owned
# /usr/local prefix. This lets the dropped-privilege `node` user auto-update the CLI
# (and globally install other tools) at runtime without sudo — otherwise Claude logs
# "Auto-update failed: no write permission to npm prefix" on every start.
ENV NPM_CONFIG_PREFIX=/home/node/.npm-global \
    PATH=/home/node/.npm-global/bin:$PATH

# Claude Code CLI. Installs the latest release into the writable prefix above; the CLI
# then auto-updates itself at runtime, so the cached image stays current without rebuilds.
RUN mkdir -p /home/node/.npm-global \
    && npm install -g @anthropic-ai/claude-code \
    && chown -R node:node /home/node/.npm-global

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
