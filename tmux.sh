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
D=$(cd "$(dirname "$0")" && pwd)
SESSION=${VOICE_SESSION:-voice}
CONFIG_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/voice
AUTH_FILE="$CONFIG_DIR/api-auth"
ENV_FILE="$CONFIG_DIR/client.env"
[[ -r $ENV_FILE ]] && . "$ENV_FILE"
API_URL=${VOICE_API_URL:-https://www.deliktas.de/voice}

case "${1:-}" in
    stop)
        tmux kill-session -t "$SESSION" 2>/dev/null && echo "stopped" || echo "not running"
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

< <(true) 2>/dev/null
tmux new-session -d -s "$SESSION" -c "$D" -n voice \
    "pi --session-id voice --session-dir '$D/sessions' \
        --thinking off \
        --append-system-prompt '$D/skills/voice-understanding/SKILL.md' \
        --skill '$D/skills/voice-understanding' \
        -e '$D/pi-extension/voice-bridge.ts'"
tmux set-option -t "$SESSION" remain-on-exit on

tmux split-window -h -t "$SESSION:0" -c "$D" \
    "VOICE_API_URL='$API_URL' python3 -u '$D/agent-pull.py'"
tmux split-window -v -t "$SESSION:0.1" -c "$D" \
    "bash '$D/remote-pane.sh' '' '$API_URL/'"
tmux select-pane -t "$SESSION:0.0"
[[ "${1:-}" == start ]] && { echo "started (tmux attach -t $SESSION)"; exit 0; }
exec tmux attach -t "$SESSION"
