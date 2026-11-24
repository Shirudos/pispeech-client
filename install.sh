#!/usr/bin/env bash
# pispeech-client: the pi agent session that talks to a pispeech-server over the LAN.
#
#   ./install.sh --api https://www.deliktas.de/voice [--user voice] [--password ...]
#               [--autostart]
#   ./install.sh            asks for the API url and the credentials
#
# Installs: the speechtext/speechreply commands, ~/.config/voice/, and a tmux session that
# runs pi plus the bridge that carries speech to the server and answers back.
set -uo pipefail
cd "$(dirname "$0")"
HERE=$PWD
CONFIG=${XDG_CONFIG_HOME:-$HOME/.config}/voice
BINDIR=${VOICE_BIN_DIR:-$HOME/.local/bin}

# Android/Termux (GrapheneOS phone, tablet): aarch64, no root, packages through `pkg`,
# no systemd, and the app is killed by Doze unless a wake-lock is held. Everything else
# about the client is the same - the microphone and the speaker are the browser page.
IS_TERMUX=0
[[ -n ${TERMUX_VERSION:-} || ${PREFIX:-} == *com.termux* ]] && IS_TERMUX=1

# keep what a previous install configured: re-running must never silently change the url,
# the model or the session name (a second installation on the same machine shares nothing)
ENV_FILE="$CONFIG/client.env"
[[ -r $ENV_FILE ]] && . "$ENV_FILE"

API_URL=${VOICE_API_URL:-""}; USER_NAME=""; PASSWORD=""; AUTOSTART=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --api) API_URL=${2:?--api needs a url}; shift 2 ;;
        --user) USER_NAME=${2:?--user needs a name}; shift 2 ;;
        --password) PASSWORD=${2:?--password needs a value}; shift 2 ;;
        --autostart) AUTOSTART=1; shift ;;
        -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
    esac
done

say() { printf '\n== %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

say "prerequisites"
if (( IS_TERMUX )); then
    missing=()
    for tool in python tmux curl; do
        case $tool in
            python) have python3 || missing+=("$tool") ;;
            *) have "$tool" || missing+=("$tool") ;;
        esac
    done
    if (( ${#missing[@]} )); then
        echo "  installing in Termux: ${missing[*]}"
        pkg install -y "${missing[@]}" || { echo "pkg install failed" >&2; exit 1; }
    fi
    echo "  termux: python3, tmux, curl present"
fi
have python3 || { echo "python3 missing" >&2; exit 1; }
have tmux    || { echo "tmux missing" >&2; exit 1; }
# pi often sits in ~/.local/bin, which a non-login ssh shell does not have in PATH
PI=${VOICE_PI:-$(command -v pi || echo "$HOME/.local/bin/pi")}
[[ -x $PI ]] || { echo "pi (the coding agent) not found - install it or set VOICE_PI" >&2; exit 1; }
have curl    || { echo "curl missing" >&2; exit 1; }
python3 -c 'import urllib.request, json, ssl' \
    || { echo "python3 lacks urllib/ssl - install the full python3 package" >&2; exit 1; }

# identity the server shows in the page's "answered by" list
if [[ -z ${VOICE_CLIENT:-} ]]; then
    if (( IS_TERMUX )); then
        VOICE_CLIENT=$(getprop ro.product.model 2>/dev/null | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9')
        VOICE_CLIENT=${VOICE_CLIENT:-phone}
    else
        VOICE_CLIENT=$(hostname 2>/dev/null || echo client)
    fi
fi

if [[ -z $API_URL ]]; then
    read -r -p "API base url: " API_URL
    API_URL=${API_URL:-http://127.0.0.1:8088}
fi
API_URL=${API_URL%/}

if [[ -z $USER_NAME ]]; then
    read -r -p "user name for the API: " USER_NAME
fi
if [[ -z $PASSWORD ]]; then
    read -r -s -p "password: " PASSWORD; echo
fi

STATE=${XDG_STATE_HOME:-$HOME/.local/state}/voice
mkdir -p "$CONFIG" "$BINDIR" "$STATE"
umask 077
printf '%s:%s\n' "$USER_NAME" "$PASSWORD" > "$CONFIG/api-auth"
umask 022
cat > "$CONFIG/client.env" <<ENV
# read by tmux.sh
VOICE_API_URL=$API_URL
# the model the voice agent uses; the router default can abort mid-request
VOICE_MODEL=${VOICE_MODEL:-deepseek/deepseek-flash}
# the tmux session name: two installations on one machine must not share it
VOICE_SESSION=${VOICE_SESSION:-voice}
VOICE_PI="$PI"
# the name the server shows in the page's "answered by" list
VOICE_CLIENT=${VOICE_CLIENT:-}
ENV
chmod 600 "$CONFIG/api-auth"
echo "  credentials stored in $CONFIG/api-auth (0600)"
echo "  this machine is called '$VOICE_CLIENT' in the page"

say "commands: speechtext / speechreply"
for name in speechtext speechreply; do
    # Git Bash has no real symlinks: ln silently writes a copy there, and some setups refuse
    # outright. Whatever happens, the command has to exist and be executable.
    ln -sfn "$HERE/bin/speech" "$BINDIR/$name" 2>/dev/null
    [[ -x $BINDIR/$name ]] || cp "$HERE/bin/speech" "$BINDIR/$name" || { echo "  cannot write $BINDIR/$name" >&2; exit 1; }
    chmod +x "$BINDIR/$name"
done
# PATH: a note nobody reads is why the commands "go missing". Write it once, idempotently.
# The rc file follows the login shell (the author's is fish); VOICE_RC overrides it.
RC=${VOICE_RC:-}
if [[ -z $RC ]]; then
    case ${SHELL##*/} in
        fish) RC=$HOME/.config/fish/config.fish ;;
        zsh)  RC=$HOME/.zshrc ;;
        *)    RC=$HOME/.bashrc ;;
    esac
fi
# fish's rc is only there once fish has run once
[[ $RC == */config.fish ]] && mkdir -p "${RC%/*}"
case "$RC" in
    */config.fish) EXPORT="set -gx PATH \"$BINDIR\" \$PATH" ;;
    *)            EXPORT="export PATH=\"$BINDIR:\$PATH\"" ;;
esac
case ":$PATH:" in
    *":$BINDIR:"*) echo "  $BINDIR is already on PATH" ;;
    *) if grep -qsF 'pispeech-client: speechtext' "$RC" 2>/dev/null; then
           echo "  $RC already adds $BINDIR - open a new shell"
       else
           printf '\n# pispeech-client: speechtext/speechreply\n%s\n' "$EXPORT" >> "$RC" \
               && echo "  added $BINDIR to PATH in $RC (new shells see it)" \
               || { echo "  add to your shell rc manually:"; echo "    $EXPORT"; }
       fi ;;
esac
command -v speechtext >/dev/null 2>&1 \
    && echo "  speechtext/speechreply ready" \
    || echo "  created in $BINDIR - not on this shell's PATH yet (open a new shell)"

say "checking the server"
if curl -fsS -m 6 -u "$(cat "$CONFIG/api-auth")" "$API_URL/health"; then
    echo
else
    echo "  the API did not answer with those credentials - fix that before worrying about the rest"
fi

if (( AUTOSTART )) && (( IS_TERMUX )); then
    say "autostart (Termux:Boot)"
    DIR=$HOME/.termux/boot
    mkdir -p "$DIR"
    cat > "$DIR/voice.sh" <<BOOT
#!/data/data/com.termux/files/usr/bin/bash
# started by the Termux:Boot app after boot - install it from F-Droid once
termux-wake-lock
cd "$HERE" && ./tmux.sh start
BOOT
    chmod +x "$DIR/voice.sh"
    echo "  $DIR/voice.sh"
    echo "  needs the Termux:Boot app (F-Droid). Without it, start ./tmux.sh by hand."
elif (( AUTOSTART )); then
    say "autostart"
    DIR=$HOME/.config/autostart
    mkdir -p "$DIR"
    cat > "$DIR/voice-agent.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Voice agent
Comment=pi + speech bridge in tmux
Exec=$HERE/tmux.sh start
Terminal=false
X-GNOME-Autostart-enabled=true
DESKTOP
    echo "  $DIR/voice-agent.desktop"
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
