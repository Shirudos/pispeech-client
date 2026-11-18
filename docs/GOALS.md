# What this side is for

This is the machine that *thinks*: pi, the coding agent, plus the small bridge that feeds it
your speech and carries its answers back to the speaker. All models live on the
`pispeech-server` host; this machine needs no microphone, no GPU and no audio libraries.

The project-wide goals, use cases and non-goals are written down once, in the server repo:
**`pispeech-server/docs/GOALS.md`**. Read that for the "why". This file only records what
changes when the *client* is the thing you are looking at.

## Use cases from this side

1. **Agent at the desktop.** `./tmux.sh`, talk into the page, the answer is spoken. The
   agent has this machine's files, shells and git repos.
2. **Agent on the laptop.** Same thing, same server, different machine: the laptop's files,
   the laptop's `pi`, the same URL and password. Nothing else has to be installed twice.
3. **Both at once.** Desktop and laptop attached simultaneously; each sentence goes to
   exactly one of them (the server decides, see `pispeech-server/docs/ARCHITECTURE.md` →
   *Who gets which request*). Each answer is spoken by the page that asked.
4. **Dictation.** `speechtext` in any shell, or `speechtext -w` from a script: the next
   sentence as a line on stdout, no editor plugin needed.
5. **The agent reads its own answers back.** `speechreply` prints what was just spoken, so a
   follow-up like "the second sentence was wrong" has something to point at.

## What this side must not do

- **No models, no audio capture, no synthesis.** If a feature needs a GPU or a microphone,
  it belongs on the server; this machine stays a thin, dependable client.
- **No inbound port.** Everything is outbound HTTP (`/pending`, `/reply`), so the client
  works from behind any NAT, on a laptop that changes networks, or on a phone hotspot.
- **No second opinion on the answer.** The agent answers once; the server's dispatch decides
  who answers, not this script.

## What "working" means

- Start it with one command; a red ring in the page and a `-> agent:` line in the bridge pane
  when you speak.
- Answers spoken within about a second of the agent finishing.
- Killing the network for a minute loses no answer: the bridge retries the POST and keeps the
  file offset until it succeeded.
- Two machines attached: no duplicate answers, no sentence swallowed, both listed in
  `GET /clients` on the server.
- After a reboot: `~/.config/autostart/voice-agent.desktop` (installed with `--autostart`)
  brings the session back, nothing to click.
