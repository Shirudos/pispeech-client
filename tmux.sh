#!/usr/bin/env bash
# The whole client in one tmux session:
#
#   ┌──────────────────────────┬────────────────┐
#   │ pi (the agent)           │ speech bridge  │
#   │                          ├────────────────┤
#   │                          │ api status     │
#   └──────────────────────────┴────────────────┘
#
#   ./tmux.sh          start if needed, then attach
#   ./tmux.sh start    detached (what a systemd unit or autostart would call)
#   ./tmux.sh stop     kill the session
#   ./tmux.sh status   panes + API health
set -uo pipefail
# speechtext/speechreply live in ~/.local/bin, which a non-login ssh shell does not have
export PATH="$HOME/.local/bin:$PATH"
D=$(cd "$(dirname "$0")" && pwd)
CONFIG_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/voice
AUTH_FILE="$CONFIG_DIR/api-auth"
ENV_FILE="$CONFIG_DIR/client.env"
[[ -r $ENV_FILE ]] && . "$ENV_FILE"   # before the defaults below: the file is the config
SESSION=${VOICE_SESSION:-voice}
API_URL=${VOICE_API_URL:-https://www.deliktas.de/voice}
# a pinned model beats the router default: some default routes abort mid-request
MODEL=${VOICE_MODEL:-deepseek/deepseek-flash}
# ssh logins often lack ~/.local/bin in PATH, and pi usually lives there
PI=${VOICE_PI:-$(command -v pi || echo "$HOME/.local/bin/pi")}
# the name the server knows this machine by (hostname is "localhost" on Android)
CLIENT=${VOICE_CLIENT:-$(hostname 2>/dev/null || echo client)}
IS_TERMUX=0
[[ -n ${TERMUX_VERSION:-} || ${PREFIX:-} == *com.termux* ]] && IS_TERMUX=1

case "${1:-}" in
    stop)
        tmux kill-session -t "$SESSION" 2>/dev/null && echo "stopped" || echo "not running"
        command -v termux-wake-unlock >/dev/null && termux-wake-unlock
        exit 0 ;;
    status)
        if ! tmux has-session -t "$SESSION" 2>/dev/null; then echo "session: not running"; exit 0; fi
        tmux list-panes -t "$SESSION:0" -F "#{pane_index} #{pane_pid} #{pane_dead}" \
            | while read -r index pid dead; do
                leaf=$pid
                while child=$(pgrep -P "$leaf" 2>/dev/null | head -1); do leaf=$child; done
                name=$(ps -o args= -p "$leaf" 2>/dev/null | cut -c1-44)
                [[ $dead == 1 ]] && echo "pane $index: DEAD (command exited)" || echo "pane $index: ${name:-shell}"
            done
        AUTH=(); [[ -r $AUTH_FILE ]] && AUTH=(-u "$(cat "$AUTH_FILE")")
        curl -fsS -m 4 "${AUTH[@]}" "$API_URL/health" >/dev/null 2>&1 \
            && echo "api: up ($API_URL)" || echo "api: unreachable or unauthorized ($API_URL)"
        exit 0 ;;
esac

if tmux has-session -t "$SESSION" 2>/dev/null; then
    [[ "${1:-}" == start ]] && { echo "already running"; exit 0; }
    exec tmux attach -t "$SESSION"
fi

# The voice session is its own agent: none of the user's coding setup (extensions, skills,
# prompt templates, MCP) - those told it to end answers with a "skipped / risk" footer that
# was then read out loud. The bridge adds the voice prompt as a section of the system prompt,
# read again before every run, so editing SKILL.md applies to the next turn. Any
# --append-system-prompt replaces ~/.pi/agent/APPEND_SYSTEM.md; this one only says where pi runs.
# Android: without a wake-lock Doze freezes the app and the session stops answering
(( IS_TERMUX )) && command -v termux-wake-lock >/dev/null && termux-wake-lock

PI_CMD="env VOICE_PROMPT='$D/skills/voice-understanding/SKILL.md' '$PI' \
        --session-id voice --session-dir '$D/sessions' --model '$MODEL' --thinking off \
        --no-extensions --no-skills --no-prompt-templates \
        -e '$D/pi-extension/voice-bridge.ts' \
        --append-system-prompt 'This machine: $CLIENT. Your working directory is on it.'"
BRIDGE_CMD="VOICE_API_URL='$API_URL' VOICE_CLIENT='$CLIENT' python3 -u '$D/agent-pull.py'"
STATUS_CMD="bash '$D/remote-pane.sh' '$API_URL' '$API_URL/'"
# the panes inherit the tmux *server's* environment, not this script's: without this a pane
# started by autostart or by a non-login shell has no speechtext/speechreply on PATH
PANE_PATH="$HOME/.local/bin:$PATH"

CREATED=0
tmux new-session -d -s "$SESSION" -c "$D" -n voice "$PI_CMD" 2>/dev/null && CREATED=1
# Windows: the unofficial win32 tmux cannot spawn a command line or a cwd - every
# new-session/split-window with -c or an argument fails with "spawn failed", while the
# script went on to print "started". Bare panes inherit this directory, so the same
# commands are typed into them instead.
if (( ! CREATED )); then
    tmux new-session -d -s "$SESSION" \
        || { echo "tmux could not start the session" >&2; exit 1; }
    echo "tmux cannot spawn commands here - typing them into bare panes"
fi
tmux set-environment -t "$SESSION" PATH "$PANE_PATH"
tmux set-option -t "$SESSION" remain-on-exit on

if (( CREATED )); then
    tmux split-window -h -t "$SESSION:0" -c "$D" "$BRIDGE_CMD"
    tmux split-window -v -t "$SESSION:0.1" -c "$D" "$STATUS_CMD"
else
    tmux rename-window -t "$SESSION:0" voice
    tmux send-keys -t "$SESSION:0.0" -l "$PI_CMD" && tmux send-keys -t "$SESSION:0.0" Enter
    tmux split-window -h -t "$SESSION:0" && \
        { tmux send-keys -t "$SESSION:0.1" -l "$BRIDGE_CMD"; tmux send-keys -t "$SESSION:0.1" Enter; }
    tmux split-window -v -t "$SESSION:0.1" && \
        { tmux send-keys -t "$SESSION:0.2" -l "$STATUS_CMD"; tmux send-keys -t "$SESSION:0.2" Enter; }
fi
tmux select-pane -t "$SESSION:0.0"
[[ "${1:-}" == start ]] && { echo "started (tmux attach -t $SESSION)"; exit 0; }
exec tmux attach -t "$SESSION"
