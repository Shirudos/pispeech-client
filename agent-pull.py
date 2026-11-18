#!/usr/bin/env python3
"""Runs on the machine that hosts the agent: pulls work, pushes answers.

The API host never connects here and there is no tunnel - this process only makes
outbound HTTP requests to it:

    GET  /pending?wait=20   -> [{"id", "text"} | {"id", "abort": true}, ...]   (long-poll)
    POST /reply             <- one record per line of agent-out.log:
                               {"text"} a sentence, {"ack": id} pi has it, {"final": true}

Two loops: one long-polls for work and appends it to agent-in.log, the other tails
agent-out.log and posts every record, in order, retrying a failed post instead of skipping
it. Work is only taken while the pi extension's heartbeat is fresh, so a request is never
leased to this machine while pi is not running to read it.
"""

import base64
import json
import os
import socket
import ssl
import sys
import threading
import time
import urllib.parse
import urllib.request

STATE = os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state"), "voice")
IN_LOG = os.path.join(STATE, "agent-in.log")
OUT_LOG = os.path.join(STATE, "agent-out.log")
ALIVE = os.path.join(STATE, "bridge.alive")   # touched by the pi extension every 0.3 s
HISTORY = os.path.join(STATE, "history.jsonl")
API = os.environ.get("VOICE_API_URL", "http://127.0.0.1:8088").rstrip("/")
AUTH_FILE = os.path.join(os.path.expanduser("~/.config/voice/api-auth"))
# several machines may run this at once; the API host hands each request to exactly one
CLIENT = (os.environ.get("VOICE_CLIENT") or socket.gethostname() or "client").strip()[:40]
WAIT_S = 20        # how long the server may hold a /pending request
ALIVE_S = 5.0      # the extension's heartbeat is older than this: pi is not running

# TLS is verified. VOICE_INSECURE_TLS=1 is only for a LAN server with a self-signed
# certificate; never for a public host, the Basic-auth password travels in these requests.
if os.environ.get("VOICE_INSECURE_TLS") == "1":
    _context = ssl._create_unverified_context()  # noqa: S323 - explicit opt-in above
else:
    _context = ssl.create_default_context()
OPENER = urllib.request.build_opener(urllib.request.HTTPSHandler(context=_context))


def log(*a):
    print(*a, file=sys.stderr, flush=True)


def credentials():
    """user:password for the Basic auth on /voice/, from env or ~/.config/voice/api-auth."""
    value = os.environ.get("VOICE_API_AUTH", "")
    if value:
        return value.strip()
    try:
        with open(AUTH_FILE) as handle:
            return handle.read().strip()
    except OSError:
        return ""


def headers(extra=None):
    out = {"X-Client": CLIENT, "X-Bridge": "2", **(extra or {})}
    auth = credentials()
    if auth:
        out["Authorization"] = "Basic " + base64.b64encode(auth.encode()).decode()
    return out


def request(path, payload=None, timeout=10):
    data = json.dumps(payload).encode() if payload is not None else None
    extra = {"Content-Type": "application/json"} if data else {}
    with OPENER.open(urllib.request.Request(API + path, data=data, headers=headers(extra)),
                     timeout=timeout) as response:
        return json.load(response)


def publish(kind, text):
    """input.txt / reply.txt / history.jsonl, so speechtext and speechreply work."""
    if not text:
        return
    path = os.path.join(STATE, f"{kind}.txt")
    with open(path + ".tmp", "w") as handle:
        handle.write(text + "\n")
    os.replace(path + ".tmp", path)
    with open(HISTORY, "a") as handle:
        handle.write(json.dumps({"ts": time.strftime("%Y-%m-%dT%H:%M:%S"), "kind": kind,
                                 "text": text}) + "\n")


def agent_alive():
    try:
        return time.time() - os.path.getmtime(ALIVE) < ALIVE_S
    except OSError:
        return False


def pull():
    """Long-poll for work, but only while pi is there to read it."""
    backoff, said_waiting = 0.3, False
    while True:
        if not agent_alive():
            if not said_waiting:
                log("pi is not running (no heartbeat from the extension) - taking no work")
                said_waiting = True
            time.sleep(1)
            continue
        if said_waiting:
            log("pi is back - taking work again")
            said_waiting = False
        try:
            items = request(f"/pending?client={urllib.parse.quote(CLIENT)}&wait={WAIT_S}",
                            timeout=WAIT_S + 15).get("items", [])
            backoff = 0.3
        except Exception as error:  # noqa: BLE001 - the API host may be down
            log(f"pending failed ({error}), retrying in {backoff:.0f}s")
            time.sleep(backoff)
            backoff = min(backoff * 2, 30)
            continue
        for item in items:
            with open(IN_LOG, "a") as handle:
                handle.write(json.dumps(item) + "\n")
            if item.get("text"):
                publish("input", item["text"])
            log(f"-> agent: {'abort' if item.get('abort') else item.get('text', '')[:70]}")


def push():
    """Post every record the extension appends, in order; a failed post is retried."""
    offset = os.path.getsize(OUT_LOG)  # never replay old answers
    backoff = 0.3
    while True:
        try:
            size = os.path.getsize(OUT_LOG)
            if size < offset:
                offset = 0
            if size == offset:
                time.sleep(0.05)
                continue
            with open(OUT_LOG, "rb") as handle:
                handle.seek(offset)
                data = handle.read()
            for line in data.splitlines(keepends=True):
                if not line.endswith(b"\n"):
                    break  # still being written, the next round gets it
                try:
                    record = json.loads(line)
                except json.JSONDecodeError:
                    offset += len(line)  # not ours, forget it
                    continue
                request("/reply", record)
                offset += len(line)       # only once delivered: a failed post retries it
                if record.get("text"):
                    publish("reply", record["text"])
                    log(f"<- agent: {record['text'][:70]}")
                elif record.get("final"):
                    log("<- agent: done" + (" (aborted)" if record.get("aborted") else "")
                        + (" (failed)" if record.get("error") else ""))
            backoff = 0.3
        except Exception as error:  # noqa: BLE001
            log(f"reply failed ({error}), retrying in {backoff:.0f}s")
            time.sleep(backoff)
            backoff = min(backoff * 2, 30)


def main():
    os.makedirs(STATE, exist_ok=True)
    open(IN_LOG, "a").close()
    open(OUT_LOG, "a").close()
    log(f"agent bridge {CLIENT!r}: {API} (pending -> {IN_LOG}, {OUT_LOG} -> reply)")
    threading.Thread(target=push, daemon=True).start()
    pull()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
