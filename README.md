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

`rsync` over `scp -r` for updates: it skips what is already there. The `.git` directory
travels along, so `git log` and `git status` work on the new machine too.

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
| server → agent | `GET /pending` (polled every 0.3 s) | `agent-pull.py` appends to `agent-in.log` |
| agent → server | `POST /reply` | `agent-pull.py` tails `agent-out.log` |
| agent ↔ session | `agent-in.log` / `agent-out.log` | the pi extension `pi-extension/voice-bridge.ts` |

Only outbound HTTP from this machine: no tunnel, no open port, nothing to punch through NAT.

## Documentation

- `docs/GOALS.md` — use cases, what this side must and must not do, what "working" means.
- `docs/AGENT-BRIDGE.md` — the three processes, the sentence-to-answer protocol, two
  machines on one server, and a troubleshooting table.
- The project-wide goals and the scheduling contract live in the server repo:
  `pispeech-server/docs/GOALS.md` and `docs/ARCHITECTURE.md`.

## The agent's instructions

`skills/voice-understanding/SKILL.md` is both the skill and the appended system prompt: how
to answer when the words are spoken, how short, no URLs or code, and that speech-to-text
mangles names so it should try the obvious alternatives before giving up. Edit it, then
`/reload` inside the pi pane (or restart the session).

## Install on another machine (laptop)

Exactly the same: copy the repo, run `./install.sh` with the same API url and credentials,
then `./tmux.sh`. The pi session lives on that machine, so the agent works with that
machine's files while the speech models stay on the server. Nothing else has to match —
only the URL and the password.

Several machines may run at once — that is the point of the server's dispatcher: each
sentence is handed to exactly one idle machine (exclusive lease, backpressure, answers
broadcast to every open page). `GET /clients` on the server shows who is attached, and
`VOICE_CLIENT=name` overrides the name (default: the hostname).

One thing to know on `ssh`: `~/.local/bin` is often missing from a non-login PATH, so `pi`
and `speechtext` look absent. `tmux.sh` adds it for the panes; for your own shell add
`export PATH="$HOME/.local/bin:$PATH"`.

Autostart on the login machine: `./install.sh ... --autostart` writes
`~/.config/autostart/voice-agent.desktop` for you (`Exec=tmux.sh start`); everything then
lives in the `voice` tmux session.
