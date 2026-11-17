#!/usr/bin/env python3
"""Runs on the machine that hosts the agent: pulls work, pushes answers.

The API host never connects here and there is no tunnel - this process only makes
outbound HTTP requests to it:

    GET  /pending   -> [{"text": "..."} | {"abort": true}, ...]   (emptied by the read)
    POST /reply     <- {"text": "..."}                            one per answer

So the page can live on any machine that can reach the API host, and the agent stays here.
"""

import json
import os
import socket
import sys
import time
import urllib.parse
import urllib.request

STATE = os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state"), "voice")
IN_LOG = os.path.join(STATE, "agent-in.log")
OUT_LOG = os.path.join(STATE, "agent-out.log")
API = os.environ.get("VOICE_API_URL", "http://127.0.0.1:8088").rstrip("/")
AUTH_FILE = os.path.join(os.path.expanduser("~/.config/voice/api-auth"))
# several machines may run this at once; the API host hands each request to exactly one
CLIENT = (os.environ.get("VOICE_CLIENT") or socket.gethostname() or "client").strip()[:40]


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
POLL_S = 0.3
HISTORY = os.path.join(STATE, "history.jsonl")


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


def log(*a):
    print(*a, file=sys.stderr, flush=True)


class Insecure(urllib.request.HTTPSHandler):
    """The API host uses a self-signed certificate on the LAN."""

    def __init__(self):
        import ssl

        context = ssl.create_default_context()
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
        super().__init__(context=context)


OPENER = urllib.request.build_opener(Insecure())


def headers(extra=None):
    bases = dict(extra or {})
    auth = credentials()
    if auth:
        import base64

        bases["Authorization"] = "Basic " + base64.b64encode(auth.encode()).decode()
    return bases


def get_json(path):
    request = urllib.request.Request(API + path, headers=headers({"X-Client": CLIENT}))
    with OPENER.open(request, timeout=10) as response:
        return json.load(response)


def post_json(path, payload):
    request = urllib.request.Request(
        API + path, data=json.dumps(payload).encode(),
        headers=headers({"Content-Type": "application/json", "X-Client": CLIENT}),
    )
    with OPENER.open(request, timeout=10) as response:
        return response.read()


def main():
    os.makedirs(STATE, exist_ok=True)
    open(IN_LOG, "a").close()
    open(OUT_LOG, "a").close()
    offset = os.path.getsize(OUT_LOG)  # never replay old answers
    log(f"agent bridge {CLIENT!r}: {API} (pending -> {IN_LOG}, {OUT_LOG} -> reply)")

    backoff = POLL_S
    while True:
        try:
            for item in get_json(f"/pending?client={urllib.parse.quote(CLIENT)}").get("items", []):
                with open(IN_LOG, "a") as handle:
                    handle.write(json.dumps(item) + "\n")
                if item.get("text"):
                    publish("input", item["text"])
                log(f"-> agent: {'abort' if item.get('abort') else item.get('text', '')[:70]}")
            backoff = POLL_S
        except Exception as error:  # noqa: BLE001 - the API host may be down
            log(f"pending failed ({error}), retrying in {backoff:.0f}s")
            time.sleep(backoff)
            backoff = min(backoff * 2, 30)
            continue

        try:
            size = os.path.getsize(OUT_LOG)
            if size < offset:
                offset = 0
            if size > offset:
                with open(OUT_LOG) as handle:
                    handle.seek(offset)
                    data = handle.read()
                # Move past a line only once it has been delivered, so a failed POST
                # retries the answer instead of dropping it.
                consumed = 0
                for line in data.splitlines(keepends=True):
                    if not line.endswith("\n"):
                        break  # still being written, the next poll gets it
                    try:
                        text = json.loads(line).get("text")
                    except json.JSONDecodeError:
                        consumed += len(line.encode())  # not ours, forget it
                        continue
                    if text:
                        post_json("/reply", {"text": text})
                        publish("reply", text)
                        log(f"<- agent: {text[:70]}")
                    consumed += len(line.encode())
                offset += consumed
            backoff = POLL_S
        except Exception as error:  # noqa: BLE001
            log(f"reply failed ({error}), retrying in {backoff:.0f}s")
            time.sleep(backoff)
            backoff = min(backoff * 2, 30)
            continue

        time.sleep(POLL_S)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
