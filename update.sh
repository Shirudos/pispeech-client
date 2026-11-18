#!/usr/bin/env bash
# Bring an already installed client up to date: stop, reinstall, start, check.
#
#   ./update.sh          uses ~/.config/voice/ (api url, credentials, model)
#   ./update.sh --no-start   only stop and reinstall
#
# This is the only thing to run after copying a new version over the old one
# (scp -r pispeech-client host:ai/ or rsync -a ...). It must stay that way: if updating
# needs a hand-edited file or a remembered command, the installer is wrong, not the user.
set -uo pipefail
cd "$(dirname "$0")"
CONFIG=${XDG_CONFIG_HOME:-$HOME/.config}/voice
AUTH_FILE="$CONFIG/api-auth"
ENV_FILE="$CONFIG/client.env"
START=1
[[ ${1:-} == --no-start ]] && START=0

say() { printf '\n== %s\n' "$*"; }
die() { printf 'update failed: %s\n' "$*" >&2; exit 1; }

[[ -x ./install.sh ]] || die "install.sh missing next to update.sh"
[[ -r $AUTH_FILE ]] || die "no $AUTH_FILE - this client was never installed, run ./install.sh"
[[ -r $ENV_FILE ]] || die "no $ENV_FILE - this client was never installed, run ./install.sh"
# shellcheck disable=SC1090
. "$ENV_FILE"
[[ -n ${VOICE_API_URL:-} ]] || die "$ENV_FILE has no VOICE_API_URL"

credentials=$(cat "$AUTH_FILE")
user=${credentials%%:*}
password=${credentials#*:}
[[ -n $user && -n $password ]] || die "$AUTH_FILE is not user:password"

say "tests"
if command -v node >/dev/null; then
    node test_bridge.mjs || die "the bridge test failed, nothing was changed"
else
    echo "  node not on PATH: skipping the bridge test"
fi

say "stop"
./tmux.sh stop

say "reinstall (same configuration, so nothing is asked)"
VOICE_MODEL=${VOICE_MODEL:-deepseek/deepseek-flash} \
VOICE_PI=${VOICE_PI:-} \
    ./install.sh --api "$VOICE_API_URL" --user "$user" --password "$password" || die "install.sh"

if (( START )); then
    say "start"
    ./tmux.sh start || die "tmux start"
    for _ in $(seq 1 30); do   # the bridge needs a moment before the API sees it
        name=$(curl -fsS -m 4 -u "$credentials" "$VOICE_API_URL/clients" 2>/dev/null \
               | python3 -c 'import json,sys; print(" ".join(c["name"] for c in json.load(sys.stdin)["clients"]))' 2>/dev/null)
        [[ $name == *"$(hostname)"* ]] && break
        sleep 1
    done
    say "check"
    curl -fsS -m 5 -u "$credentials" "$VOICE_API_URL/health" >/dev/null \
        && echo "  api: ok" || die "api unreachable or unauthorized ($VOICE_API_URL)"
    printf '  attached machines: %s\n' "${name:-none}"
    [[ $name == *"$(hostname)"* ]] && echo "  this machine is attached" \
        || echo "  NOTE: this machine is not in the client list yet; look at pane 1: tmux attach -t voice"
fi

say "done"
