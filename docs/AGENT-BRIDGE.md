# The three processes in the `voice` tmux session

```
pane 0  pi            the agent, with the voice system prompt and the bridge extension
pane 1  agent-pull.py the only thing that talks to the API host
pane 2  remote-pane.sh  health of the API every 5 s (with the Basic auth)
```

## How a sentence becomes an answer

| step | where | file |
|---|---|---|
| the page ends a sentence and posts it | server | `serve.py` → `dispatch.py` |
| the bridge leases it | client | `agent-pull.py` (`GET /pending?client=<hostname>`) |
| the agent sees it as input | client | `agent-in.log` → `pi-extension/voice-bridge.ts` → `ctx.sendMessage`-style injection |
| the agent answers | client | the extension appends to `agent-out.log` |
| the bridge delivers it | client + server | `POST /reply` → `/replies` → the page speaks |
| dictation history | client | `input.txt`, `reply.txt`, `history.jsonl` |

Both logs live in `~/.local/state/voice/`. They are append-only text: a stuck bridge can be
inspected with `tail -f`, and its position in `agent-out.log` is tracked by byte offset, so a
restart never replays old answers.

## Rules the bridge follows

- **Outbound only.** No listener, no tunnel. The server never connects to this machine.
- **One request at a time.** It asks for the next request only after delivering the previous
  answer — that is what makes a second machine useful instead of a race.
- **Nothing is dropped.** A `POST /reply` that fails keeps its offset and is retried with
  backoff (0.3 s → 30 s) instead of being skipped.
- **Answered requests are removed, queued ones never are.** `dispatch.Pool.done()` removes
  exactly the request this machine answered.
- **`{"abort": true}` is Ctrl+C.** It arrives like a transcript when the page hears "stop"
  (or the ⏹ button is pressed) and the extension turns it into `ctx.abort()`. Nothing waits
  afterwards: the next sentence is a new instruction, no "continue" and no resume phrase.
- **The abort path is part of the protocol.** `{"abort": true}` arrives like a transcript and
  the extension turns it into `ctx.abort()`, so speaking over an answer cancels the run
  instead of queueing behind it.

## Which page talks to which machine

The page you speak into is answered by the agent on the same machine (the server matches the
browser's address to the address this bridge polls from), or by the machine picked in the
page's *answered by* selector / `?target=<name>` on the URL. Consequences for this machine:

- `VOICE_CLIENT` (default: the hostname) is the name the picker shows. Rename it if the
  hostname is not what you want to see in the list.
- A request aimed at another machine never arrives here; nothing to configure.
- A request aimed at *this* machine waits until this machine is free instead of being sent
  elsewhere — speak, then wait for the answer, do not expect the other machine to take over.

## Two machines, one server

Nothing here coordinates with the other machine; all coordination is server-side leases.
The consequences you can observe:

- `GET /clients` on the server lists both, with `busy`/`idle` and how many requests each took.
- Machines take turns: whoever was served earlier gets the next sentence, provided the other
  machine is polling right now. A machine that is alone is served immediately.
- If a machine is closed mid-answer, its lease expires after two minutes and the sentence
  goes back to the pool.
- The spoken answer is broadcast to every open page, so it does not matter which machine
  produced it.

## Troubleshooting, in the order that finds the answer fastest

| symptom | look at |
|---|---|
| the page has a red ring but nothing happens | `speechtext` — if it stays empty, the server never produced a transcript |
| transcript arrives, no answer | pane 0 of the `voice` session: the agent may have hit a model error |
| answer written, never spoken | server log `~/.local/state/voice-server/api.log` (`reply: …`) and `/replies` |
| "API DOWN or unauthorized" in pane 2 | `~/.config/voice/api-auth` content, then `curl -u … $URL/health` |
| the wrong machine answered | `GET /clients` — it is the one that was idle and polled first |
| the answer is not addressed to this machine's files | a second client took it; that is expected, both are equal |
