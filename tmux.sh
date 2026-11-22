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

tmux new-session -d -s "$SESSION" -c "$D" -n voice \
    "env VOICE_PROMPT='$D/skills/voice-understanding/SKILL.md' '$PI' \
        --session-id voice --session-dir '$D/sessions' --model '$MODEL' --thinking off \
        --no-extensions --no-skills --no-prompt-templates \
        -e '$D/pi-extension/voice-bridge.ts' \
        --append-system-prompt 'This machine: $CLIENT. Your working directory is on it.'"
tmux set-option -t "$SESSION" remain-on-exit on

tmux split-window -h -t "$SESSION:0" -c "$D" \
    "VOICE_API_URL='$API_URL' VOICE_CLIENT='$CLIENT' python3 -u '$D/agent-pull.py'"
tmux split-window -v -t "$SESSION:0.1" -c "$D" \
    "bash '$D/remote-pane.sh' '$API_URL' '$API_URL/'"
tmux select-pane -t "$SESSION:0.0"
[[ "${1:-}" == start ]] && { echo "started (tmux attach -t $SESSION)"; exit 0; }
exec tmux attach -t "$SESSION"
