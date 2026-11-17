#!/usr/bin/env bash
# pispeech-client: the pi agent session that talks to a pispeech-server over the LAN.
#
#   ./install.sh --api https://www.deliktas.de/voice [--user voice] [--password ...]
#   ./install.sh            asks for the API url and the credentials
#
# Installs: the speechtext/speechreply commands, ~/.config/voice/, and a tmux session that
# runs pi plus the bridge that carries speech to the server and answers back.
set -uo pipefail
cd "$(dirname "$0")"
HERE=$PWD
CONFIG=${XDG_CONFIG_HOME:-$HOME/.config}/voice
BINDIR=${VOICE_BIN_DIR:-$HOME/.local/bin}

API_URL=""; USER_NAME=""; PASSWORD=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --api) API_URL=$2; shift 2 ;;
        --user) USER_NAME=$2; shift 2 ;;
        --password) PASSWORD=$2; shift 2 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

say() { printf '\n== %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

say "prerequisites"
have python3 || { echo "python3 missing" >&2; exit 1; }
have tmux    || { echo "tmux missing" >&2; exit 1; }
# pi often sits in ~/.local/bin, which a non-login ssh shell does not have in PATH
PI=${VOICE_PI:-$(command -v pi || echo "$HOME/.local/bin/pi")}
[[ -x $PI ]] || { echo "pi (the coding agent) not found - install it or set VOICE_PI" >&2; exit 1; }
have curl    || { echo "curl missing" >&2; exit 1; }
python3 - <<'PY' || exit 1
import urllib.request, sys
print("  python urllib ok")
PY

if [[ -z $API_URL ]]; then
    read -r -p "API base url [https://www.deliktas.de/voice]: " API_URL
    API_URL=${API_URL:-https://www.deliktas.de/voice}
fi
API_URL=${API_URL%/}

if [[ -z $USER_NAME ]]; then
    read -r -p "user name for the API: " USER_NAME
fi
if [[ -z $PASSWORD ]]; then
    read -r -s -p "password: " PASSWORD; echo
fi

mkdir -p "$CONFIG" "$BINDIR"
umask 077
printf '%s:%s\n' "$USER_NAME" "$PASSWORD" > "$CONFIG/api-auth"
umask 022
cat > "$CONFIG/client.env" <<ENV
# read by tmux.sh
VOICE_API_URL=$API_URL
# the model the voice agent uses; the router default can abort mid-request
VOICE_MODEL=${VOICE_MODEL:-deepseek/deepseek-flash}
VOICE_PI=$PI
ENV
chmod 600 "$CONFIG/api-auth"
echo "  credentials stored in $CONFIG/api-auth (0600)"

say "commands: speechtext / speechreply"
ln -sfn "$HERE/bin/speech" "$BINDIR/speechtext"
ln -sfn "$HERE/bin/speech" "$BINDIR/speechreply"
case ":$PATH:" in
    *":$BINDIR:"*) ;;
    *) echo "  note: $BINDIR is not on PATH" ;;
esac

say "checking the server"
if curl -fsS -m 6 -u "$(cat "$CONFIG/api-auth")" "$API_URL/health"; then
    echo
else
    echo "  the API did not answer with those credentials - fix that before worrying about the rest"
fi

say "done"
cat <<EOF
  start the session:   $HERE/tmux.sh
  attach later:        tmux attach -t voice
  speech to text now:  speechtext      (last thing the mic heard)
                       speechreply     (last answer the agent gave)
  every transcript:    $HOME/.local/state/voice/history.jsonl
  buffers:             $HOME/.local/state/voice/{input.txt,reply.txt}

The agent gets your speech through the pi extension in
$HERE/pi-extension/voice-bridge.ts, and the answers come back out of
$HOME/.local/state/voice/agent-out.log.
EOF
