// Voice bridge: lets agent-pull.py talk to this interactive Pi session, in both directions.
//
//   state/agent-in.log   {"id","text"} or {"id","abort":true} - injected here as your input
//   state/agent-out.log  what this session says: {"text"} per finished sentence (spoken),
//                        {"screen"} per fenced code block (shown, never spoken),
//                        {"activity"} per tool started, {"ack": id} once a request is in,
//                        {"final": true, ...} per run
//   state/bridge.alive   touched every second: agent-pull only takes work while it is fresh
//
// Neither side needs a socket, a server or a second Pi process: append-only files.
// VOICE_PROMPT names the voice instructions; they are read again before every run, so an
// edit applies to the next turn without /reload.
import { appendFileSync, closeSync, existsSync, openSync, readFileSync, readSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const STATE = join(process.env.XDG_STATE_HOME || join(process.env.HOME || ".", ".local", "state"), "voice");
const IN = join(STATE, "agent-in.log");
const OUT = join(STATE, "agent-out.log");
const ALIVE = join(STATE, "bridge.alive");
const PROMPT = process.env.VOICE_PROMPT || "";
const POLL_MS = 100; // the delay between a request arriving and pi having it
const ALIVE_MS = 1000;

// Fenced blocks are for the screen. A sentence is never cut inside one, and while a fence is
// still open nothing after its start is cut at all: its "." are not ends of sentences.
const fenced = (text: string) => {
  let masked = "", open = -1;
  const parts = text.split("```");
  parts.forEach((part, i) => {
    const inside = i % 2 === 1;
    if (inside && i === parts.length - 1) open = masked.length; // unclosed: everything after waits
    masked += (i ? "```" : "") + (inside ? "x".repeat(part.length) : part);
  });
  return { masked, limit: open < 0 ? text.length : open };
};

// One finished piece of the answer -> spoken prose and shown blocks, in order.
const pieces = (chunk: string) =>
  chunk.split("```").flatMap((part, i) => {
    if (i % 2 === 1) return part.trim() ? [{ screen: part.replace(/^[\w+-]*\n/, "").trimEnd() }] : [];
    const prose = part.replace(/\s+/g, " ").trim();
    return prose ? [{ text: prose }] : [];
  });

const textOf = (message: any) =>
  (message?.content || [])
    .filter((block: any) => block.type === "text")
    .map((block: any) => block.text)
    .join("");

export default function (pi: any) {
  let offset = -1; // -1 until session_start, so a restart never replays old lines
  let ctx: any; // abort needs the event context, kept from the last event we saw
  let streamed = ""; // text already sent out sentence by sentence
  let lastStop = ""; // stopReason of the last assistant message: "error" means the run failed
  let timer: any;
  const delivered = new Set<number | string>(); // request ids already handed to pi
  const out = (record: object) => appendFileSync(OUT, JSON.stringify(record) + "\n");

  let alive = 0;
  const drain = () => {
    if (Date.now() - alive >= ALIVE_MS) {
      try {
        writeFileSync(ALIVE, String(Date.now()));
        alive = Date.now();
      } catch {
        // the state dir vanished: agent-pull sees pi as gone, which is the truth
      }
    }
    if (!existsSync(IN)) return;
    const size = statSync(IN).size;
    if (offset < 0 || offset > size) offset = size; // fresh start: skip what is already there
    if (size <= offset) return;
    const fd = openSync(IN, "r");
    let text = "";
    try {
      const buffer = Buffer.alloc(size - offset);
      readSync(fd, buffer, 0, buffer.length, offset);
      text = buffer.toString("utf8");
    } finally {
      closeSync(fd);
    }
    const complete = text.lastIndexOf("\n") + 1; // a half-written line waits for the next tick
    offset += Buffer.byteLength(text.slice(0, complete));
    for (const line of text.slice(0, complete).split("\n")) {
      if (!line.trim()) continue;
      let request: any;
      try {
        request = JSON.parse(line);
      } catch {
        continue; // not ours
      }
      const { id, text: said, abort } = request;
      if (id !== undefined) {
        if (delivered.has(id)) continue; // never twice, whatever happens upstream
        delivered.add(id);
      }
      if (abort) ctx?.abort();
      else if (said) {
        // the label tells the model this is transcribed speech, not typing
        pi.sendUserMessage(`[voice] ${said}`, { deliverAs: "steer" });
        if (id !== undefined) out({ ack: id });
      }
    }
  };

  pi.on("session_start", async (_event: any, c: any) => {
    ctx = c;
    offset = existsSync(IN) ? statSync(IN).size : 0;
    clearInterval(timer);
    timer = setInterval(drain, POLL_MS);
    timer.unref?.();
  });

  pi.on("session_shutdown", async () => {
    clearInterval(timer); // a reload starts a new instance; the old one must stop reading
  });

  pi.on("before_agent_start", async (event: any) => {
    if (!PROMPT) return;
    let voice: string;
    try {
      voice = readFileSync(PROMPT, "utf8");
    } catch {
      return; // the file is being edited: this run keeps the last version
    }
    const sections = event.systemPromptOptions?.sections;
    if (sections) {
      sections.voice = voice;
      return;
    }
    return { systemPrompt: `${event.systemPrompt}\n\n<voice>\n${voice}\n</voice>` };
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
    const text = textOf(event.message);
    if (!text || text === streamed) return;
    const { masked, limit } = fenced(text);
    const settled = masked.slice(0, limit);
    const fenceEnd = settled.lastIndexOf("```\n"); // a closed block ends a piece too
    const cut = Math.max(settled.lastIndexOf(". "), settled.lastIndexOf("! "), settled.lastIndexOf("? "),
      settled.lastIndexOf(".\n"), fenceEnd < 0 ? -1 : fenceEnd + 2);
    if (cut < streamed.length) return; // no complete sentence yet
    const fresh = text.slice(streamed.length, cut + 1);
    streamed = text.slice(0, cut + 1);
    for (const piece of pieces(fresh)) out(piece);
  });

  pi.on("message_end", async (event: any, c: any) => {
    ctx = c;
    const message = event.message;
    if (message?.role !== "assistant") return;
    lastStop = message.stopReason || "";
    // joined exactly like the streaming branch above, or the "rest" slice would be
    // computed against a different string and repeat or drop text
    const rest = textOf(message).slice(streamed.length);
    streamed = "";
    for (const piece of pieces(rest)) out(piece);
  });

  // What it is doing while it says nothing: shown on the page as "working: bash", never spoken.
  pi.on("tool_execution_start", async (event: any, c: any) => {
    ctx = c;
    if (!event.parentToolCallId) out({ activity: event.toolName });
  });

  // The run is over and pi will not continue on its own: the server may hand this machine
  // the next request. Aborted runs end here too (pi skips agent_before_settle for them).
  pi.on("agent_settled", async (event: any, c: any) => {
    ctx = c;
    out({ final: true, aborted: !!event.aborted, error: lastStop === "error" });
    lastStop = "";
  });
}
