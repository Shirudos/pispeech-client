# pispeech-client

Your side of the voice setup: the pi agent, plus the bridge that carries speech to a
`pispeech-server` and brings the answers back. The microphone and the speaker come from a
web page served by the server, so this machine needs no audio device and no models.

```
browser page (server)  ── audio ──►  whisper/piper (server)
        ▲                                   │ transcript
        │ answer                            ▼
        └──────── /replies ◄── agent-pull.py ──► pi (here, in tmux)
```

## Install

No remote, no `git clone` — copy the repo as it is, `.git` included, and keep the history:

```sh
# from the machine that already has it
scp -r pispeech-client other-host:ai/
ssh other-host 'cd ~/ai/pispeech-client && ./install.sh \
    --api https://www.deliktas.de/voice --user voice --password "..."'

# or both in one go, non-interactive
rsync -a --exclude sessions pispeech-client/ other-host:ai/pispeech-client/
ssh other-host 'cd ~/ai/pispeech-client && ./install.sh --api ... --user voice --password ... && ./tmux.sh start'
```

For an existing installation, copy the new version over the old one and run one command:

```sh
scp -r pispeech-client other-host:ai/     # or rsync -a ... (skips what is already there)
ssh other-host 'cd ~/ai/pispeech-client && ./update.sh'
```

`update.sh` stops the session, reinstalls with the *stored* configuration (nothing is asked),
starts it again and checks that this machine shows up in the server's client list. If updating
ever needs more than that, the installer is wrong, not the operator.

```sh
./tmux.sh                    # pi + bridge + status, then open the page
```

Requirements: `python3`, `tmux`, `pi`, `curl`. Nothing else — no GPU, no ffmpeg, no
models, and no `jq` (the installer and `bin/speech` use python3 for JSON).

The installer writes:

| file | |
|---|---|
| `~/.config/voice/api-auth` | `user:password` for the Basic auth (0600) |
| `~/.config/voice/client.env` | `VOICE_API_URL=...` and `VOICE_MODEL=...`, read by `tmux.sh` |
| `~/.local/bin/speechtext` | print what the mic last heard |
| `~/.local/bin/speechreply` | print the agent's last answer |

## Using it

```
┌──────────────────────────┬────────────────┐
│ pi (the agent)           │ speech bridge  │
│                          ├────────────────┤
│                          │ api status     │
└──────────────────────────┴────────────────┘
```

Talk into the page the server serves. Spoken "stop" aborts the agent's run like Ctrl+C (the
⏹ button does the same); "voice off" / "mic off" mute the speaker or the microphone; nothing
ever waits for a resume keyword — the next sentence is the next instruction. Your sentence is transcribed there, the transcript is
picked up by `agent-pull.py` and lands in the pi session like typed input; the answer is
written back to the server and read out loud by the page.

```sh
speechtext              # what it heard
speechreply             # what it answered
speechtext -w           # block until the next sentence, print it
speechtext -c           # to the clipboard
tail -f ~/.local/state/voice/history.jsonl
```

## How the two halves talk

| direction | file | who writes |
|---|---|---|
| server → agent | `GET /pending?wait=20` (long-poll, only while pi's heartbeat is fresh) | `agent-pull.py` appends to `agent-in.log` |
| agent → server | `POST /reply`: each sentence, `{"ack": id}`, `{"final": true}` per run | `agent-pull.py` tails `agent-out.log` |
| agent ↔ session | `agent-in.log` / `agent-out.log` | the pi extension `pi-extension/voice-bridge.ts` |

Only outbound HTTP from this machine: no tunnel, no open port, nothing to punch through NAT.
TLS certificates are verified; `VOICE_INSECURE_TLS=1` turns that off for a LAN server with a
self-signed certificate (never for a public host: the password travels in those requests).

## Documentation

- `docs/GOALS.md` — use cases, what this side must and must not do, what "working" means.
- `docs/AGENT-BRIDGE.md` — the three processes, the sentence-to-answer protocol, two
  machines on one server, and a troubleshooting table.
- `docs/TERMUX.md` — the same client on an Android phone: packages, wake-lock, boot hook,
  picking the phone in the page, and why it needs no microphone.
- `docs/WINDOWS.md` — the same client on Windows in Git Bash: no WSL, the win32 tmux quirk
  `tmux.sh` works around, and what was verified.
- The project-wide goals and the scheduling contract live in the server repo:
  `pispeech-server/docs/GOALS.md` and `docs/ARCHITECTURE.md`.

## Configuration

Everything lives in `~/.config/voice/`; `install.sh` writes it once and `update.sh` keeps it.

| where | key | meaning |
|---|---|---|
| `client.env` | `VOICE_API_URL` | the server, e.g. `https://www.deliktas.de/voice` |
| | `VOICE_CLIENT` | the name the page shows (`pixel8`, `adelpc`); default: hostname, or the device model on Android |
| | `VOICE_MODEL` | model for the voice agent (`deepseek/deepseek-flash`); the router default aborts mid-request |
| | `VOICE_SESSION` | tmux session name, so two installations on one host do not collide |
| | `VOICE_PI` | absolute path to `pi` (ssh and autostart shells often lack `~/.local/bin`) |
| `api-auth` | `user:password` | Basic auth for the server, mode 0600 |
| state | `~/.local/state/voice/` | `input.txt`, `reply.txt`, `history.jsonl`, `agent-in.log`, `agent-out.log` |

Environment overrides are read at start, so `VOICE_CLIENT=pixel8 ./tmux.sh` works without
editing the file. `VOICE_INSECURE_TLS=1` accepts a self-signed certificate (a LAN server
without a real certificate; not needed behind apache).

| command | flags |
|---|---|
| `./install.sh` | `--api`, `--user`, `--password`, `--autostart`, `--help`; without `--user`/`--password` it keeps the stored ones (a piped or cron run cannot answer the prompt) |
| `./update.sh` | `--no-start` (stop and reinstall only) |
| `./tmux.sh` | no argument = start/attach, `start`, `stop`, `status` |
| `speechtext` / `speechreply` | `-w` wait for the next, `-f` follow, `-c` copy to clipboard |

## The agent's instructions

`skills/voice-understanding/SKILL.md` is the voice session's system prompt: how to answer
when every word is spoken, how short, no URLs or code, what "stop" and "weiter" do, to check
facts with a tool instead of guessing, and that speech-to-text mangles names so it should try
the obvious alternatives before giving up. The bridge reads it again before every run, so an
edit applies to the next thing you say: no `/reload`, no restart.

The voice session loads none of your coding setup (`--no-extensions --no-skills
--no-prompt-templates`): no MCP servers, no subagents, no ponytail footer read out loud. If you
want one tool back, add exactly that one with `-e` in `tmux.sh`, not discovery.

## Install on another machine (laptop)

Exactly the same: copy the repo, run `./install.sh` with the same API url and credentials,
then `./tmux.sh`. The pi session lives on that machine, so the agent works with that
machine's files while the speech models stay on the server. Nothing else has to match —
only the URL and the password.

Several machines may run at once — that is the point of the server's dispatcher: each
sentence is handed to exactly one machine, a page stays with the machine that answered it,
and each answer is spoken by the page that asked. `GET /clients` on the server shows who is
attached, and `VOICE_CLIENT=name` overrides the name (default: the hostname).

One thing to know on `ssh`: `~/.local/bin` is often missing from a non-login PATH, so `pi`
and `speechtext` look absent. `tmux.sh` puts it on the panes' PATH (`tmux set-environment`),
and `install.sh` writes the export into your shell's rc file (`~/.bashrc`, `~/.zshrc`, or
`~/.config/fish/config.fish` — it looks at `$SHELL`, `VOICE_RC` overrides it) instead of only
printing the line.

Autostart on the login machine: `./install.sh ... --autostart` writes
`~/.config/autostart/voice-agent.desktop` for you (`Exec=tmux.sh start`); everything then
lives in the `voice` tmux session.

## An Android phone (Termux)

pi runs on the phone as well (Pixel 8, GrapheneOS, Termux), so the phone can be its own
agent, with its own files — `./install.sh` handles Termux: it installs `python tmux curl`
through `pkg`, names the machine after the device model (`pixel8`, because `hostname` is
`localhost`), takes a wake-lock so Doze does not freeze it, and `--autostart` writes a
`~/.termux/boot/voice.sh` hook for the Termux:Boot app. Full details, including why no
microphone is needed there: `docs/TERMUX.md`.

```sh
tar czf - --exclude sessions -C pispeech-client . | ssh DNPixel8 'mkdir -p ~/ai/pispeech-client && tar xzf - -C ~/ai/pispeech-client'
ssh DNPixel8 'cd ~/ai/pispeech-client && ./install.sh --api https://www.deliktas.de/voice \
    --user voice --password "…" && ./tmux.sh start'
```

Pick `pixel8` in the page once (`?target=pixel8` also works): through the router every
device on the home network looks like one address, so the phone cannot be matched by address.

## An agent for the phone on the server (alternative)

If the phone has no pi of its own, one can run on the server instead: the same repo,
installed there, talking to `serve.py` directly (no apache, no password on localhost):

```sh
rsync -a --exclude sessions pispeech-client/ server:ai/pispeech-client/
ssh server 'cd ~/ai/pispeech-client && ./install.sh --api http://127.0.0.1:8088 \
    --user local --password local && ./tmux.sh start'
```

It shows up as the server's hostname (`adelicious`) in `/clients` and in the page's
*answered by* selector. On the phone, pick it once there, or bookmark
`https://<server>/voice/?target=adelicious`. The pick matters: through the router every
device on the home network looks like the same address, so the phone would otherwise be
matched to the desktop. The server's pi uses the model provider configured in the server's
own `~/.pi/agent`; it works on the server's files, and on other machines only through the
ssh keys that already exist there.

A headless server has no desktop autostart. To survive a reboot, add to the server's
`crontab -e` (adjust the pi node path to the one in `~/.local/share/pi-node/`):

```
@reboot sleep 30 && $HOME/ai/pispeech-server/deploy/start.sh >> $HOME/.local/state/voice-server/boot.log 2>&1
@reboot sleep 60 && PATH=$HOME/.local/share/pi-node/node-v22.22.3-linux-x64/bin:$HOME/.local/bin:/usr/bin:/bin $HOME/ai/pispeech-client/tmux.sh start >> $HOME/.local/state/voice/boot.log 2>&1
```
