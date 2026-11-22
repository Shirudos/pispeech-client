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
| the bridge leases it | client | `agent-pull.py` (`GET /pending?client=<hostname>&wait=20`, a long-poll) |
| the agent sees it as input | client | `agent-in.log` → `pi-extension/voice-bridge.ts` → `pi.sendUserMessage("[voice] …", {deliverAs: "steer"})` |
| the agent answers | client | the extension appends `{"ack"}`, each sentence, and `{"final"}` to `agent-out.log` |
| the bridge delivers it | client + server | `POST /reply` → that page's `/replies` → the page speaks |
| dictation history | client | `input.txt`, `reply.txt`, `history.jsonl` |

Both logs live in `~/.local/state/voice/`. They are append-only text: a stuck bridge can be
inspected with `tail -f`, and its position in `agent-out.log` is tracked by byte offset, so a
restart never replays old answers.

## Rules the bridge follows

- **Outbound only.** No listener, no tunnel. The server never connects to this machine.
- **Work only while pi runs.** The extension touches `bridge.alive` every second; `agent-pull.py`
  takes no work while that heartbeat is older than 5 s, so a request is never leased to a
  machine whose agent cannot read it (pi restarting, crashed, not started yet).
- **One answer at a time, steering any time.** A machine holds one request until pi's run
  settles (`{"final": true}` from `agent_settled`). Meanwhile, more words from the page it is
  answering still arrive at once and reach pi as steering for the running turn.
- **Never twice.** Every request has an id; the extension delivers each id once and answers
  `{"ack": id}`. The server never hands out an acknowledged request again.
- **Nothing is dropped.** A `POST /reply` that fails keeps its offset and is retried with
  backoff (0.3 s doubling to 5 s) instead of being skipped. Five seconds is deliberate: after
  a server restart the loop has to be back almost at once, not half a minute later.
- **`{"abort": true}` is Ctrl+C and is never answered.** The page sends it for "stop" and the
  ⏹ button; the extension calls `ctx.abort()`, the run settles as aborted, and the machine is
  free for the next sentence. Talking over an answer is *not* an abort: it silences the page
  and steers the agent, so work in progress survives.
- **"weiter" / "continue" arrives as the word `continue`.** That is the only way to resume
  after an abort: the run is gone, so the agent has to be asked to carry on.

## Records the bridge posts

`agent-out.log` is a line-per-record file and `agent-pull.py` forwards each record to
`POST /reply` with `X-Bridge: 2`. Five kinds, all optional from the agent's point of view:

| record | when | what the page does |
|---|---|---|
| `{"ack": id}` | the request reached pi | stops showing it as "not confirmed" |
| `{"text": "…"}` | one finished sentence while the answer is still being written | speaks it (queued, never cut off) |
| `{"screen": "…"}` | one fenced code block | shows it, never reads it |
| `{"activity": "bash"}` | a tool started | a small progress line, not spoken |
| `{"final": true, "aborted": …}` | pi's run settled (`agent_settled`) | ends the lease; the machine takes the next sentence |

A fence is never cut mid-block: the extension holds the sentence until the block closes, so a
code listing is either shown whole or not at all.

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
- If a machine is closed mid-answer, it stops polling; two minutes later the sentence goes
  back to the pool, unless pi had already acknowledged it (then it is never repeated).
- A page stays with the machine that answered it, and its next words reach that machine
  even while it works: they arrive in pi as steering, not as a new queue entry.
- The spoken answer goes to the page that asked, not to every open page.

## Troubleshooting, in the order that finds the answer fastest

| symptom | look at |
|---|---|
| the page has a red ring but nothing happens | `speechtext` — if it stays empty, the server never produced a transcript |
| transcript arrives, no answer | pane 0 of the `voice` session: the agent may have hit a model error |
| answer written, never spoken | server log `~/.local/state/voice-server/api.log` (`reply: …`) and `/replies` |
| "API DOWN or unauthorized" in pane 2 | `~/.config/voice/api-auth` content, then `curl -u … $URL/health` |
| the wrong machine answered | `GET /clients` — it is the one that was idle and polled first |
| the answer is not addressed to this machine's files | a second client took it; that is expected, both are equal |
