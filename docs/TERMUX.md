# The client on an Android phone (Termux)

A Pixel 8 with GrapheneOS and Termux runs the same client as a laptop: pi, the bridge and
`speechtext`. Only the plumbing differs — Termux has no systemd, the app is frozen by Doze
without a wake-lock, and `hostname` says `localhost`, which is useless as a name.

**No audio device is needed.** The microphone and the speaker are the browser page on the
server; Termux only runs the thinker. That is why this installs in a few seconds and needs
no Termux:API audio packages.

## What the phone needs

Termux (F-Droid build, not the Play Store one) and an sshd if you want to reach it from
another machine. The package list used to get the host reachable:

```sh
pkg update && pkg upgrade
pkg install openssh          # then run `sshd` once: it listens on 8022
pkg install python tmux curl git rsync fish fastfetch nmap ripgrep fd
```

Only `python tmux curl` are required; `install.sh` installs whichever of those three is
missing. `git` and `rsync` are convenience: git keeps the repo history on the phone, rsync
makes copying a new version cheaper than tar over ssh.

`~/.ssh/authorized_keys` (or a password on port 8022) has to exist for `ssh DNPixel8`:

```
Host DNPixel8
    User u0_a227
    HostName DNPixel8
    IdentityFile ~/.ssh/adeliktasde
    Port 8022
```

`pi` itself must already be on `PATH` (`command -v pi`); on this phone it is
`$PREFIX/bin/pi`, version 1.6.0, with the model credentials in `~/.pi/agent/`.

## Install

On the machine that has the repo (rsync is usually missing on a fresh Termux, so a tar pipe
works from anywhere):

```sh
ssh DNPixel8 'mkdir -p ~/ai/pispeech-client'
tar czf - --exclude sessions --exclude __pycache__ -C pispeech-client . \
  | ssh DNPixel8 'tar xzf - -C ~/ai/pispeech-client'

ssh DNPixel8 'cd ~/ai/pispeech-client && ./install.sh \
    --api https://www.deliktas.de/voice --user voice --password "…"'
```

With `rsync` installed on the phone the first step is just

```sh
rsync -a --exclude sessions pispeech-client/ DNPixel8:ai/pispeech-client/
```

and with `git` installed `git log` on the phone shows the same history as the machine the
copy came from, so a change can be traced back there.

## What the installer does differently on Termux

| | |
|---|---|
| missing tools | `pkg install -y python tmux curl`, no sudo, no prompt |
| the name | `getprop ro.product.model` → `pixel8`, because `hostname` is `localhost`. This is what the page's *answered by* list shows. Override with `VOICE_CLIENT=…` |
| `--autostart` | writes `~/.termux/boot/voice.sh` (wake-lock + `tmux.sh start`) instead of a `.desktop` file — see below |
| everything else | identical: `~/.config/voice/{api-auth,client.env}`, `~/.local/bin/speechtext`, `~/.local/state/voice/` |

## Running it

```sh
cd ~/ai/pispeech-client
./tmux.sh            # pi + bridge + status, attaches the session
./tmux.sh start      # detached (what the boot hook calls)
./tmux.sh stop       # also releases the wake-lock
./update.sh          # after copying a new version: stop, reinstall, start, verify
```

`tmux.sh start` takes a **wake-lock** (`termux-wake-lock`) before it starts the session and
`tmux.sh stop` releases it. Without it Android's Doze freezes the app after a few minutes of
screen-off, the poller stops, and the page's sentences go to another machine or nowhere.

Keep Termux in the background, not swiped away: swiping the app from the recents list kills
the session even with a wake-lock. Battery cost is small — the phone only polls
`/pending` and runs pi when you talk.

## Autostart after a reboot (optional)

```sh
ssh DNPixel8 'cd ~/ai/pispeech-client && ./install.sh --autostart …'   # writes ~/.termux/boot/voice.sh
```

That hook only runs if the **Termux:Boot** app (F-Droid) is installed and Termux has been
started once after installing it. Without the app the file is inert and you start the
session by hand — which is the default here on purpose: a client that is always attached can
take sentences you meant for another machine.

## Choosing the phone in the page

Through the router's hairpin NAT every device on the home network reaches apache as the same
address (`192.168.101.1`), and on mobile data the phone's address is not on the LAN at all.
The address match therefore cannot tell the phone from the desktop, so pick it once:

- in the page's **answered by** selector: `pixel8`, kept in `localStorage`, or
- bookmark `https://www.deliktas.de/voice/?target=pixel8`.

`GET /clients` on the server shows whether the phone is attached before you wonder why
nothing happened.

## Troubleshooting

| symptom | check |
|---|---|
| nothing reaches the pi session | `curl -u … $API/clients` — is `pixel8` listed and idle? |
| attached but silent after the screen went off | `termux-wake-lock` held? `./tmux.sh stop && ./tmux.sh start` |
| the session vanished | Termux was swiped away; start it again, ideally with Termux:Boot |
| `speechtext: command not found` | `export PATH="$HOME/.local/bin:$PATH"` (the panes already have it) |
| pi answers nothing, an error in pane 0 | the phone's `~/.pi/agent` credentials; `pi --list-models` |
| answers go to the wrong machine | the page's selector is on *auto* and matched the desktop — pick `pixel8` |
