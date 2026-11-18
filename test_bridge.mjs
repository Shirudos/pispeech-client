#!/usr/bin/env node
// The pi extension, driven by a fake pi: node test_bridge.mjs (node 22.18+ strips the types).
// Pins: requests reach pi once (as steering, labelled), every request is acknowledged, an
// abort is Ctrl+C, a half-written line waits, answers stream sentence by sentence, every run
// ends with a "final", and the voice prompt is read again before each run.
import { appendFileSync, existsSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const home = mkdtempSync(join(tmpdir(), "bridge-"));
process.env.XDG_STATE_HOME = home;
process.env.VOICE_PROMPT = join(home, "prompt.md");
writeFileSync(process.env.VOICE_PROMPT, "speak briefly");
const STATE = join(home, "voice");
const { mkdirSync } = await import("node:fs");
mkdirSync(STATE, { recursive: true });
const IN = join(STATE, "agent-in.log");
const OUT = join(STATE, "agent-out.log");
writeFileSync(IN, JSON.stringify({ id: 0, text: "old, before pi started" }) + "\n");

const { default: bridge } = await import("./pi-extension/voice-bridge.ts");
const handlers = {}, sent = [];
let aborts = 0;
const pi = {
  on: (name, fn) => { handlers[name] = fn; },
  sendUserMessage: (text, options) => sent.push([text, options?.deliverAs]),
};
const ctx = { abort: () => { aborts += 1; } };
bridge(pi);
const tick = () => new Promise((r) => setTimeout(r, 400));
const records = () => existsSync(OUT)
  ? readFileSync(OUT, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l)) : [];
const check = (ok, what) => { if (!ok) { console.error("FAIL:", what); process.exit(1); } };

await handlers.session_start({}, ctx);
const keepAlive = setInterval(() => {}, 1000);   // the bridge's own timer is unref'd
appendFileSync(IN, [
  JSON.stringify({ id: 1, text: "open the settings" }),
  JSON.stringify({ id: 1, text: "open the settings" }),   // the same request again
  JSON.stringify({ id: 2, abort: true }),
].join("\n") + "\n" + '{"id": 3, "text": "half');           // not finished being written
await tick();
check(existsSync(join(STATE, "bridge.alive")), "no heartbeat");
check(JSON.stringify(sent) === JSON.stringify([["[voice] open the settings", "steer"]]),
  `delivered ${JSON.stringify(sent)}`);
check(aborts === 1, "the abort was not Ctrl+C");
check(JSON.stringify(records()) === JSON.stringify([{ ack: 1 }]), `records ${JSON.stringify(records())}`);

appendFileSync(IN, ' written"}\n');
await tick();
check(sent.length === 2 && sent[1][0] === "[voice] half written", "a half-written line was lost");

// an answer streams sentence by sentence, the rest comes with message_end
const msg = (text, extra = {}) => ({ message: { role: "assistant", content: [{ type: "text", text }], ...extra } });
await handlers.message_start(msg(""), ctx);
await handlers.message_update(msg("One. Tw"), ctx);
await handlers.message_update(msg("One. Two. Thr"), ctx);
await handlers.message_end(msg("One. Two. Three.", { stopReason: "error" }), ctx);
await handlers.agent_settled({ aborted: false }, ctx);
const spoken = records().filter((r) => r.text).map((r) => r.text);
check(JSON.stringify(spoken) === JSON.stringify(["One.", "Two.", "Three."]), `spoken ${JSON.stringify(spoken)}`);
const finals = records().filter((r) => r.final);
check(finals.length === 1 && finals[0].error === true && finals[0].aborted === false, "no final, or error lost");

await handlers.agent_settled({ aborted: true }, ctx);
check(records().filter((r) => r.final).pop().aborted === true, "an aborted run did not say so");

// the voice prompt is a section of the system prompt, read again for every run
const event = { systemPromptOptions: { sections: {} }, systemPrompt: "base" };
await handlers.before_agent_start(event, ctx);
check(event.systemPromptOptions.sections.voice === "speak briefly", "no voice section");
writeFileSync(process.env.VOICE_PROMPT, "speak even more briefly");
await handlers.before_agent_start(event, ctx);
check(event.systemPromptOptions.sections.voice === "speak even more briefly", "the prompt edit did not apply");

await handlers.session_shutdown({}, ctx);
appendFileSync(IN, JSON.stringify({ id: 4, text: "after shutdown" }) + "\n");
await tick();
check(sent.length === 2, "a shut-down session kept reading");
check(!sent.some(([t]) => t.includes("old, before")), "a line from before the start was replayed");

clearInterval(keepAlive);
console.log("test_bridge ok");
