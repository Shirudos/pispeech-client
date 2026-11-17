#!/usr/bin/env bash
# What the "API host" pane shows when whisper and piper run on the other machine.
# A script, not an inline shell loop: tmux panes run through the login shell (fish here).
API="${1:-http://127.0.0.1:8088}"
PAGE="${2:-}"
while :; do
    clear
    printf '%s  api %s\n' "$(date '+%H:%M:%S')" "$API"
    [[ -n $PAGE ]] && printf 'page %s\n' "$PAGE"
    printf '\n' 
    if curl -fsS -m 2 "$API/health"; then
        printf '\n\n'
    else
        printf 'API DOWN - run ./deploy.sh\n\n'
    fi
    sleep 5
done
