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

```sh
git clone <this repo> && cd pispeech-client
./install.sh --api https://www.deliktas.de/voice --user voice --password '...'
./tmux.sh                    # pi + bridge + status, then open the page
```

Requirements: `python3`, `tmux`, `pi`, `curl`. Nothing else — no GPU, no ffmpeg, no models.

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

Talk into the page the server serves. Your sentence is transcribed there, the transcript is
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

## The agent's instructions

`skills/voice-understanding/SKILL.md` is both the skill and the appended system prompt: how
to answer when the words are spoken, how short, no URLs or code, and that speech-to-text
mangles names so it should try the obvious alternatives before giving up. Edit it, then
`/reload` inside the pi pane (or restart the session).

## Install on another machine (laptop)

Exactly the same: `./install.sh` with the same API url and credentials, then `./tmux.sh`.
The pi session lives on that machine, so the agent works with that machine's files while
the speech models stay on the server. Nothing else has to match — only the URL and the
password.
