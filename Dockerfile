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

# --- PHP + Composer (MediaWiki core/extensions) ------------------------------
# Debian 12 only ships PHP 8.2, older than current MediaWiki core requires, so PHP comes from
# Ondřej Surý's repository (packages.sury.org), which has 8.3, 8.4 and 8.5 for bookworm. Pick
# one with `--build-arg PHP_VERSION=8.5`. The extensions cover core's PHPUnit (unit +
# integration on SQLite), phpcs and Phan; `ast` lets Phan use its native parser instead of the
# much slower --allow-polyfill-parser. memory_limit is lifted because PHPUnit and Phan on core
# go well past the 128M default.
ARG PHP_VERSION=8.3
RUN curl -sSfLo /tmp/sury-keyring.deb https://packages.sury.org/debsuryorg-archive-keyring.deb \
    && dpkg -i /tmp/sury-keyring.deb && rm /tmp/sury-keyring.deb \
    && echo "deb [signed-by=/usr/share/keyrings/debsuryorg-archive-keyring.gpg] https://packages.sury.org/php/ $(. /etc/os-release && echo "$VERSION_CODENAME") main" \
        > /etc/apt/sources.list.d/php.list \
    && apt-get update && apt-get install -y --no-install-recommends \
        php${PHP_VERSION}-cli \
        php${PHP_VERSION}-common \
        php${PHP_VERSION}-intl \
        php${PHP_VERSION}-mbstring \
        php${PHP_VERSION}-xml \
        php${PHP_VERSION}-sqlite3 \
        php${PHP_VERSION}-gmp \
        php${PHP_VERSION}-bcmath \
        php${PHP_VERSION}-curl \
        php${PHP_VERSION}-readline \
        php${PHP_VERSION}-zip \
        php${PHP_VERSION}-apcu \
        php${PHP_VERSION}-ast \
    && echo 'memory_limit = -1' > /etc/php/${PHP_VERSION}/cli/conf.d/99-local.ini \
    && rm -rf /var/lib/apt/lists/*

# Composer 2, copied from the official image (for `composer update` after pulling core).
COPY --from=composer:2 /usr/bin/composer /usr/local/bin/composer

# --- Headless Chromium system libraries ---------------------------------------
# Only the shared libraries and fonts Chromium needs (libnss3, libgbm1, libatk*, …), installed by
# Playwright's own dependency list. The browser itself is version-matched to whichever
# Playwright a session uses, so it's still fetched at runtime, e.g.
# `uv run --with playwright python -m playwright install chromium` (no sudo needed).
RUN npx --yes playwright@latest install-deps chromium \
    && rm -rf /var/lib/apt/lists/* /root/.npm

# uv (fast Python package/venv manager) via the official standalone installer.
RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh

# Rust toolchain via rustup (cargo, rustc, clippy, rustfmt). Installed under the `node`
# user's home so future sessions can `rustup update` / `rustup component add` / install
# extra toolchains at runtime without sudo. PATH is set via ENV (rather than shell rc
# files) so cargo is found no matter how the process is started. The C linker Rust needs
# comes from build-essential above.
ENV RUSTUP_HOME=/home/node/.rustup \
    CARGO_HOME=/home/node/.cargo \
    PATH=/home/node/.cargo/bin:$PATH
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --no-modify-path --profile default --default-toolchain stable \
    && chown -R node:node "$RUSTUP_HOME" "$CARGO_HOME"

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

# Bake in a JDK (Temurin) and Maven so Java/Flink builds work without a per-session download.
# SDKMAN only lists the newest patch release for each major (e.g. 21.0.13.0+9-tem), so a hard
# pinned identifier would break the build at the next release; the latest Temurin for
# JAVA_MAJOR is resolved from the SDKMAN API at build time instead. Maven is SDKMAN's default.
# Installed as `node`, since SDKMAN is per-user. `sdk install java <other>` still works at runtime.
ARG JAVA_MAJOR=21
RUN gosu node bash -c ' \
        set -eo pipefail; \
        source "$SDKMAN_DIR/bin/sdkman-init.sh"; \
        id=$(curl -sSf "$SDKMAN_CANDIDATES_API/candidates/java/$SDKMAN_PLATFORM/versions/list?current=&installed=" \
            | grep -oE " $JAVA_MAJOR\.[0-9.+]+-tem" | head -1 | tr -d " ") || true; \
        test -n "$id" || { echo "no Temurin $JAVA_MAJOR found in SDKMAN" >&2; exit 1; }; \
        sdk install java "$id"; \
        sdk install maven; \
        sdk flush'
# Also expose them image-wide via SDKMAN's `current` symlinks (which `sdk default` repoints), so
# java/mvn work in shells and subprocesses that never source sdkman-init (e.g. `sh -c`).
ENV JAVA_HOME=$SDKMAN_DIR/candidates/java/current \
    PATH=$SDKMAN_DIR/candidates/java/current/bin:$SDKMAN_DIR/candidates/maven/current/bin:$PATH

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
