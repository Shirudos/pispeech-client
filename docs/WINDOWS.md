# The client on Windows (Git Bash, no WSL)

Installed and verified on Windows 10 19045 with Git Bash — no WSL, no admin rights, no
MSYS package manager. Everything the client needs already exists on a Windows box that has
Git for Windows, Python and pi; the only Windows-specific surprise is the `tmux` build, which
cannot spawn a command line — `tmux.sh` types the commands into bare panes instead.

## What has to be there

| tool | where it was | why |
|---|---|---|
| Git Bash | `C:\Program Files\Git` (bash 5.3, MINGW64/UCRT64) | runs `install.sh`, `update.sh`, `bin/speech` |
| Python 3 | `C:\Python315` (`python3` and `python` both 3.15.0) | `agent-pull.py`, JSON in the installer and `bin/speech` |
| Node | `C:\Program Files\nodejs` (v26.13.1) | the pi extension (`voice-bridge.ts`) and `test_bridge.mjs` |
| pi | `C:\Users\<user>\.pi\agent\bin\pi` (1.6.0) | the agent itself |
| curl | Git Bash's `ucrt64/bin/curl` | the health check and `remote-pane.sh` |

Nothing is installed by hand: if `python3 --version`, `node --version`, `pi --version` and
`curl --version` answer inside Git Bash, the prerequisites are met. `install.sh` also checks
`python3 -c 'import urllib.request, json, ssl'`, which the Windows Python satisfies.

`tmux` is *not* required to install; only `tmux.sh` uses it, and the fallback described under
*Starting it* covers the win32 build's inability to spawn panes.

## Install

Exactly the Linux command, in Git Bash, in the directory that holds the repo:

```sh
cd ~/Downloads/pispeech-client            # wherever the repo was copied
printf 'voice\n\n' | ./install.sh --api https://www.deliktas.de/voice
```

The two piped lines are the interactive answers (`user name`, `password`); drop the pipe and
type them when they are known. What it writes, in Windows terms:

| file | |
|---|---|
| `C:\Users\<user>\.config\voice\api-auth` | `user:password`, mode 0600 (advisory on NTFS — the file sits in the user profile, which is what actually protects it) |
| `C:\Users\<user>\.config\voice\client.env` | `VOICE_API_URL`, `VOICE_MODEL`, `VOICE_SESSION`, `VOICE_PI`, `VOICE_CLIENT` |
| `C:\Users\<user>\.local\bin\speechtext` | copy of `bin/speech` |
| `C:\Users\<user>\.local\bin\speechreply` | copy of `bin/speech` |
| `C:\Users\<user>\.local\state\voice\` | `agent-in.log`, `agent-out.log`, `history.jsonl`, `bridge.alive`, … |

Git Bash has no real symlinks by default, so `ln -sfn` in `install.sh` lands as two small
copies instead of two links. That is harmless: `bin/speech` is self-contained and reads
`$0`'s last path component to decide between transcript and answer. Re-running `update.sh`
refreshes both copies.

The client is called `DESKTOP-IDML5U3` in the page — the Windows hostname, as the installer
says. `VOICE_CLIENT=adelpc ./tmux.sh` (or an edit of `client.env`) renames it.

## `~/.local/bin` on PATH

`install.sh` prints the note; the one line that fixes it, appended to `C:\Users\<user>\.bashrc`:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

Git Bash creates `~/.bash_profile` on first login that sources `~/.bashrc`, so this is enough
for every new window.

## Starting it: `tmux.sh`

`tmux.sh` works, with one Windows-only detour. The unofficial win32 tmux build
(`tmux 3.6a-win32`, `C:\Users\<user>\tools\tmux\tmux.exe`) cannot spawn a command line and
cannot be given a working directory — every `new-session`/`split-window` with `-c` or an
argument fails with `create window failed: spawn failed`. A bare `new-session` *does* work and
inherits the directory `tmux.sh` already sits in, so `tmux.sh` falls back to starting three
bare panes and typing the same three commands into them:

```
$ ./tmux.sh start
tmux cannot spawn commands here - typing them into bare panes
started (tmux attach -t voice)
```

The session is then the normal one — pane 0 the pi agent, pane 1 `agent-pull.py`, pane 2 the
API status — and `./tmux.sh status` / `stop` work as on Linux. The fallback only runs when the
normal path fails, so nothing changes for Linux, Termux or WSL.

Two things worth knowing:

- **pi first, bridge second** is already the order the fallback types them in, because the
  bridge takes no work until the extension has written a heartbeat.
- `/c/...` paths are fine as `-e` arguments: MSYS2 converts them to `C:\...` for the native
  `node` pi launches (verified: a wrong path fails with the converted name).

Stopping is `./tmux.sh stop`, as on Linux.

`speechtext`, `speechreply`, `tail -f ~/.local/state/voice/history.jsonl` behave as on Linux.

## What was verified, and what was not

| checked | result |
|---|---|
| `./install.sh` | config, both commands, state dir written |
| `speechtext` / `speechreply` | answer `nothing (input) yet` / `nothing (reply) yet` |
| `node test_bridge.mjs` | `test_bridge ok` — the extension's protocol on Windows Node 26 |
| `pi -e pi-extension/voice-bridge.ts -p …` | extension loads, writes `bridge.alive` and `agent-out.log` |
| `python3 -u agent-pull.py` | starts, reports `pi is not running (no heartbeat …) - taking no work` until pi is up |
| `curl https://www.deliktas.de/voice/health` without credentials | `401` — the client had no password to install, so `api-auth` holds `voice:` and the health check fails until it is replaced |
| `./tmux.sh start` | prints the fallback line, starts `voice` with all three panes alive (pi TUI, `pending failed (401) … retrying`, the status pane) |
| `./tmux.sh status` / `stop` | work; pane names show `shell` because the MSYS `pgrep` does not see the native children |

Not verified: a spoken sentence end to end, because that needs the real `user:password`
(and a page open on the server). Everything up to the lease is working; the 401 is the only
gap.

## WSL, if a real Linux box is wanted

Windows Subsystem for Linux gives back the whole Linux path — a real tmux, real symlinks, real
`0600` — with one extra step: the repo has to live on the Linux side (`~/ai/pispeech-client`,
not `/mnt/c/...`, because `/mnt/c` has no POSIX permissions and horribly slow metadata), and
`python3`, `tmux`, `node` (for pi) and `pi` have to be installed inside the distribution:

```sh
wsl --install -d Ubuntu                  # admin rights, reboot
# in the Ubuntu shell, then the Linux instructions in README.md
```

Only `agent-pull.py` and the tmux panes run there; the browser page and the speech models
stay on the server, exactly as on any other client.
