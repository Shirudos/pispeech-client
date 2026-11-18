// Voice bridge: lets voice.py talk to this interactive Pi session, in both directions.
//
//   state/agent-in.log   voice.py appends {"text":"..."} - injected here as your input
//   state/agent-out.log  every assistant answer is appended here - voice.py speaks it
//
// Neither side needs a socket, a server or a second Pi process: two append-only files.
import { appendFileSync, existsSync, openSync, readSync, closeSync, statSync } from "node:fs";
import { join } from "node:path";

const STATE = join(process.env.XDG_STATE_HOME || join(process.env.HOME || ".", ".local", "state"), "voice");
const IN = join(STATE, "agent-in.log");
const OUT = join(STATE, "agent-out.log");
const POLL_MS = 300;

export default function (pi: any) {
  let offset = -1; // -1 until session_start, so a restart never replays old lines
  let ctx: any; // abort needs the event context, kept from the last event we saw
  let streamed = ""; // text already sent out sentence by sentence

  const drain = () => {
    if (!existsSync(IN)) return;
    const size = statSync(IN).size;
    if (offset < 0 || offset > size) offset = size; // fresh start: skip what is already there
    if (size <= offset) return;
    const fd = openSync(IN, "r");
    try {
      const buffer = Buffer.alloc(size - offset);
      readSync(fd, buffer, 0, buffer.length, offset);
      offset = size;
      for (const line of buffer.toString("utf8").split("\n")) {
        if (!line.trim()) continue;
        try {
          const { text, abort } = JSON.parse(line);
          if (abort) ctx?.abort();
          else if (text) pi.sendUserMessage(text, { deliverAs: "steer" });
        } catch {
          // a half-written line: the next poll picks it up
        }
      }
    } finally {
      closeSync(fd);
    }
  };

  pi.on("session_start", async (_event: any, c: any) => {
    ctx = c;
    offset = existsSync(IN) ? statSync(IN).size : 0;
    const timer = setInterval(drain, POLL_MS);
    timer.unref?.();
  });

  pi.on("message_start", async (event: any, c: any) => {
    ctx = c;
    if (event.message?.role === "assistant") streamed = "";
  });

  // Emit every finished sentence while the answer is still being written, so the
  // first one is already being spoken when the rest arrives.
  pi.on("message_update", async (event: any, c: any) => {
    ctx = c;
    if (event.message?.role !== "assistant") return;
    const text = (event.message.content || [])
      .filter((block: any) => block.type === "text")
      .map((block: any) => block.text)
      .join("");
    if (!text || text === streamed) return;
    const cut = Math.max(text.lastIndexOf(". "), text.lastIndexOf("! "), text.lastIndexOf("? "));
    if (cut < streamed.length) return; // no complete sentence yet
    const fresh = text.slice(streamed.length, cut + 1).trim();
    streamed = text.slice(0, cut + 1);
    if (fresh) appendFileSync(OUT, JSON.stringify({ text: fresh }) + "\n");
  });

  pi.on("message_end", async (event: any, c: any) => {
    ctx = c;
    const message = event.message;
    if (message?.role !== "assistant") return;
    // joined exactly like the streaming branch above, or the "rest" slice would be
    // computed against a different string and repeat or drop text
    const text = (message.content || [])
      .filter((block: any) => block.type === "text")
      .map((block: any) => block.text)
      .join("");
    const rest = text.slice(streamed.length).replace(/^\s+/, "").trim();
    streamed = "";
    if (rest) appendFileSync(OUT, JSON.stringify({ text: rest }) + "\n");
  });
}
