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
import sys
import time
import urllib.request

STATE = os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state"), "voice")
IN_LOG = os.path.join(STATE, "agent-in.log")
OUT_LOG = os.path.join(STATE, "agent-out.log")
API = os.environ.get("VOICE_API_URL", "https://192.168.101.135:8089").rstrip("/")
AUTH_FILE = os.path.join(os.path.expanduser("~/.config/voice/api-auth"))


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
    request = urllib.request.Request(API + path, headers=headers())
    with OPENER.open(request, timeout=10) as response:
        return json.load(response)


def post_json(path, payload):
    request = urllib.request.Request(
        API + path, data=json.dumps(payload).encode(),
        headers=headers({"Content-Type": "application/json"}),
    )
    with OPENER.open(request, timeout=10) as response:
        return response.read()


def main():
    os.makedirs(STATE, exist_ok=True)
    open(IN_LOG, "a").close()
    open(OUT_LOG, "a").close()
    offset = os.path.getsize(OUT_LOG)  # never replay old answers
    log(f"agent bridge: {API} (pending -> {IN_LOG}, {OUT_LOG} -> reply)")

    while True:
        try:
            for item in get_json("/pending").get("items", []):
                with open(IN_LOG, "a") as handle:
                    handle.write(json.dumps(item) + "\n")
                log(f"-> agent: {'abort' if item.get('abort') else item.get('text', '')[:70]}")
        except Exception as error:  # noqa: BLE001 - the API host may be down
            log(f"pending failed: {error}")

        try:
            size = os.path.getsize(OUT_LOG)
            if size < offset:
                offset = 0
            if size > offset:
                with open(OUT_LOG) as handle:
                    handle.seek(offset)
                    data = handle.read()
                offset = size
                for line in data.splitlines():
                    try:
                        text = json.loads(line).get("text")
                    except json.JSONDecodeError:
                        continue  # a half-written line, the next poll gets it
                    if text:
                        post_json("/reply", {"text": text})
                        log(f"<- agent: {text[:70]}")
        except Exception as error:  # noqa: BLE001
            log(f"reply failed: {error}")

        time.sleep(POLL_S)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
