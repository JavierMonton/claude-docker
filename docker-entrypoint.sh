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

# --- Auto-resume after usage limits (opt-in via CLAUDE_AUTO_RESUME=1) --------
# Claude Code has no native way to continue after the rolling usage-limit window
# resets — it stops and waits for the user to type "continue". When enabled, we
# register claude-auto-resume.sh as a StopFailure hook (matcher "rate_limit") in
# the persistent settings, and run Claude inside tmux so the hook's detached
# waiter can type "continue" into the session once the window resets. The hook
# script is a no-op without CLAUDE_AUTO_RESUME=1 and tmux, so the registration
# is harmless to sessions started without the flag.
AUTO_RESUME="${CLAUDE_AUTO_RESUME:-0}"

if [ "$AUTO_RESUME" = "1" ]; then
    SETTINGS=/home/node/.claude/settings.json
    HOOK_CMD=/usr/local/bin/claude-auto-resume.sh
    [ -s "$SETTINGS" ] || echo '{}' > "$SETTINGS"
    TMP=$(mktemp)
    # Idempotent merge: leave the file alone if our hook is already registered.
    if jq --arg cmd "$HOOK_CMD" '
        if ([.hooks.StopFailure[]?.hooks[]?.command] | index($cmd)) then .
        else .hooks.StopFailure = ((.hooks.StopFailure // []) +
            [{matcher: "rate_limit", hooks: [{type: "command", command: $cmd}]}])
        end' "$SETTINGS" > "$TMP" 2>/dev/null; then
        mv "$TMP" "$SETTINGS"
        chown "$HOST_UID:$HOST_GID" "$SETTINGS" 2>/dev/null || true
    else
        rm -f "$TMP"
        echo "claude-docker: could not register the auto-resume hook (unparseable settings.json?); continuing without auto-resume." >&2
        AUTO_RESUME=0
    fi
fi

# True when the args contain a non-interactive (print-mode) flag.
is_print_mode() {
    local a
    for a in "$@"; do
        case "$a" in
            -p|--print) return 0 ;;
        esac
    done
    return 1
}

# Print-mode runs exit instead of idling when the limit is hit, so tmux/hooks
# can't help there. Instead: re-run, and when a failure looks like a usage
# limit, wait for the reset (parsed from stderr when possible, else poll every
# 5 min) and continue the same conversation. Other failures exit untouched.
run_print_with_retry() {
    local max="${CLAUDE_AUTO_RESUME_MAX_RETRIES:-12}" attempt=0 code err target now
    local -a extra=()
    err=$(mktemp)
    while :; do
        code=0
        gosu node claude "${extra[@]}" "$@" 2> "$err" || code=$?
        cat "$err" >&2
        [ "$code" -eq 0 ] && exit 0
        grep -qiE 'limit reached|usage limit|out of extra usage|rate[ -_]?limit' "$err" || exit "$code"
        attempt=$((attempt + 1))
        [ "$attempt" -gt "$max" ] && exit "$code"
        now=$(date +%s)
        target=$(claude-auto-resume.sh --parse < "$err" || true)
        if [ -n "$target" ] && [ "$target" -gt "$now" ]; then
            target=$((target + 120))
        else
            target=$((now + 300))
        fi
        echo "claude-docker: usage limit hit — resuming at $(date -d "@$target") (attempt $attempt/$max)…" >&2
        sleep $((target - now))
        extra=(--continue)
    done
}

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
# With CLAUDE_AUTO_RESUME=1, interactive runs are wrapped in tmux (so the
# auto-resume waiter has a way to type "continue") and -p runs get a retry loop.
if [ "$#" -gt 0 ]; then
    case "$1" in
        bash|zsh|sh)
            exec gosu node "$@"
            ;;
    esac
fi

if [ "$AUTO_RESUME" = "1" ]; then
    if is_print_mode "$@"; then
        run_print_with_retry "$@"
    fi
    # tmux joins its trailing args into one shell command, so quote each arg to
    # survive prompts with spaces.
    CLAUDE_CMD=$(printf '%q ' claude "$@")
    exec gosu node tmux -f /usr/local/etc/claude-tmux.conf new-session -s claude "$CLAUDE_CMD"
fi

exec gosu node claude "$@"
