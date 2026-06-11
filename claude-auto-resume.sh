#!/usr/bin/env bash
# Auto-resume helper for the claude-docker sandbox (opt-in via CLAUDE_AUTO_RESUME=1).
#
# When a session hits the subscription usage limit, Claude Code stops mid-task
# ("5-hour limit reached ∙ resets 3pm") and waits for the user to type
# "continue" after the window resets. This script removes that manual step.
# It runs in three modes:
#
#   (no args / hook)  Invoked by Claude Code itself: the entrypoint registers it
#                     as a StopFailure hook with matcher "rate_limit", so it runs
#                     exactly when a turn dies on the usage limit. It parses the
#                     reset time off the tmux pane and arms a detached waiter.
#                     Hooks have a timeout, so the hours of waiting are done by
#                     the detached process, never by the hook process itself.
#   --wait <epoch>    The detached waiter: sleeps until <epoch>, then types
#                     "continue" into the tmux pane Claude is running in.
#   --parse           Reads text on stdin and prints the parsed reset time as a
#                     Unix epoch (also used by the entrypoint's -p retry loop).
#
# It is a silent no-op unless CLAUDE_AUTO_RESUME=1 AND it runs inside the tmux
# session the entrypoint creates, so a stale hook registration left in the
# persistent config volume can never affect a normal (non-auto-resume) session.
set -u

LOG=/tmp/claude-auto-resume.log
PIDFILE=/tmp/claude-auto-resume.pid

# Matches the CLI's limit messages, e.g. "resets 3pm", "resets at 11:30am
# (Asia/Colombo)", "Your limit will reset at 2pm (America/New_York)".
RESET_RE='[Rr]esets?( at)? ([0-9]{1,2})(:([0-9]{2}))? ?([AaPp][Mm])( \(([^)]+)\))?'

# Read text on stdin, print the reset moment as an epoch. The IANA zone from the
# message wins; otherwise $TZ (pass -e TZ=… to docker run); otherwise UTC. A
# time that already passed today is taken to mean tomorrow. Returns 1 if no
# reset time can be found.
parse_reset_epoch() {
    local text line hour min ampm zone now target
    text=$(cat)
    # The pane scrollback may contain several limit messages; the last one wins.
    line=$(grep -oE "$RESET_RE" <<<"$text" | tail -n 1)
    [ -n "$line" ] || return 1
    [[ $line =~ $RESET_RE ]] || return 1
    hour=${BASH_REMATCH[2]}
    min=${BASH_REMATCH[4]:-00}
    ampm=${BASH_REMATCH[5],,}
    zone=${BASH_REMATCH[7]:-${TZ:-UTC}}
    now=$(date +%s)
    target=$(TZ="$zone" date -d "${hour}:${min} ${ampm}" +%s 2>/dev/null) || return 1
    if [ "$target" -le "$now" ]; then
        target=$(TZ="$zone" date -d "tomorrow ${hour}:${min} ${ampm}" +%s 2>/dev/null) || return 1
    fi
    echo "$target"
}

do_wait() {
    local target="$1" pane="${TMUX_PANE:-}" now left cmd
    echo $$ > "$PIDFILE"
    trap 'rm -f "$PIDFILE"' EXIT
    while :; do
        now=$(date +%s)
        left=$((target - now))
        [ "$left" -le 0 ] && break
        # Bail out quietly if the session died (Claude exited, container stopping).
        tmux has-session 2>/dev/null || return 0
        sleep $(( left < 60 ? left : 60 ))
    done
    # Only type into the pane while Claude is still its foreground process — if
    # it already exited to a shell, "continue" would run as a shell command.
    cmd=$(tmux display-message -p ${pane:+-t "$pane"} '#{pane_current_command}' 2>/dev/null) || return 0
    case "$cmd" in
        bash|zsh|sh|dash) return 0 ;;
    esac
    tmux send-keys ${pane:+-t "$pane"} -l 'continue'
    sleep 1
    tmux send-keys ${pane:+-t "$pane"} Enter
    echo "$(date): usage-limit window reset — sent 'continue'."
}

hook_main() {
    cat > /dev/null   # drain the hook's JSON payload; we work off the pane text
    [ "${CLAUDE_AUTO_RESUME:-0}" = "1" ] || exit 0
    [ -n "${TMUX:-}" ] || exit 0
    # One waiter at a time — a still-limited "continue" fails the next turn and
    # fires this hook again, which would otherwise stack waiters.
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
        exit 0
    fi
    local text target
    text=$(tmux capture-pane -p -S -100 2>/dev/null) || exit 0
    if target=$(parse_reset_epoch <<<"$text"); then
        target=$((target + 120))          # safety margin past the advertised reset
    else
        target=$(( $(date +%s) + 900 ))   # no parseable time: just retry in 15 min
    fi
    echo "$(date): usage limit hit; sending 'continue' at $(date -d "@$target")" >> "$LOG"
    setsid bash "$0" --wait "$target" >> "$LOG" 2>&1 < /dev/null &
    exit 0
}

case "${1:-}" in
    --parse) parse_reset_epoch ;;
    --wait)  do_wait "$2" ;;
    *)       hook_main ;;
esac
