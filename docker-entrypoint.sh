#!/usr/bin/env bash
# Entrypoint for the claude-docker sandbox.
#
# Runs as root only long enough to (1) align the in-container `node` user with the
# host user's uid/gid so files written into /workspace are owned by you on the host,
# then (2) drop to the non-root `node` user to run Claude. By default Claude runs
# normally (with its usual approval prompts). Pass --dangerously-skip-permissions
# yourself to run fully autonomously; the CLI refuses that flag when launched as
# root, which is why we always drop to the non-root user before running it.
set -euo pipefail

HOST_UID="${HOST_UID:-1000}"
HOST_GID="${HOST_GID:-1000}"

CUR_UID="$(id -u node)"
CUR_GID="$(id -g node)"

# Remap the `node` user/group if the host ids differ (no-op when they already match).
if [ "$HOST_GID" != "$CUR_GID" ]; then
    groupmod -o -g "$HOST_GID" node
fi
if [ "$HOST_UID" != "$CUR_UID" ]; then
    usermod -o -u "$HOST_UID" node
fi
if [ "$HOST_UID" != "$CUR_UID" ] || [ "$HOST_GID" != "$CUR_GID" ]; then
    chown -R "$HOST_UID:$HOST_GID" /home/node
fi

# Make sure the (possibly volume-mounted) config dir is owned by the remapped user.
chown "$HOST_UID:$HOST_GID" /home/node/.claude 2>/dev/null || true

# Keep the Claude CLI current. The CLI lives in the image layer (/home/node/.npm-global),
# and the container runs with --rm, so any in-session auto-update is discarded on exit and
# every launch would otherwise revert to whatever was baked in at build time. Re-pulling the
# latest npm release on start is what actually keeps you up to date across runs. Best-effort:
# if the network is down or the registry is unreachable, we keep the baked-in version rather
# than failing to start. Set CLAUDE_AUTO_UPDATE=0 to skip this (faster start, pinned version).
if [ "${CLAUDE_AUTO_UPDATE:-1}" != "0" ]; then
    echo "claude-docker: checking for a newer Claude CLI…" >&2
    if gosu node env NPM_CONFIG_PREFIX=/home/node/.npm-global \
        npm install -g @anthropic-ai/claude-code@latest --no-fund --no-audit >/dev/null 2>&1; then
        echo "claude-docker: Claude CLI up to date ($(gosu node claude --version 2>/dev/null))." >&2
    else
        echo "claude-docker: update skipped (offline or registry unreachable); using the baked-in version." >&2
    fi
fi

# Dispatch as the non-root user.
#   (no args)            -> Claude (normal mode, with approval prompts)
#   bash | zsh | sh      -> an interactive shell (debugging)
#   anything else        -> Claude with those args passed through. Pass
#                           --dangerously-skip-permissions here to run in YOLO mode.
if [ "$#" -eq 0 ]; then
    exec gosu node claude
fi

case "$1" in
    bash|zsh|sh)
        exec gosu node "$@"
        ;;
    *)
        exec gosu node claude "$@"
        ;;
esac
