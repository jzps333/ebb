// Ebb ⇄ iMessage bridge (Photon Spectrum).
//
// Runs on a Mac and keeps Photon's connection open, because sending a text
// needs a live SDK session. It does two jobs:
//
//   inbound   every iMessage DM to the Ebb line is POSTed to
//             messaging/inbound; the replies it returns are sent back.
//   outbound  every 3 s it claims queued texts (login codes, journal relays)
//             from messaging/outbox, sends each one, and reports the result to
//             messaging/sent.
//
// Config comes from .env next to this file (see .env.example).

import { Spectrum } from "spectrum-ts";
import { imessage } from "spectrum-ts/providers/imessage";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { existsSync } from "node:fs";

const here = dirname(fileURLToPath(import.meta.url));
const envPath = join(here, ".env");
if (existsSync(envPath)) process.loadEnvFile(envPath);

const {
  SPECTRUM_PROJECT_ID,
  SPECTRUM_PROJECT_SECRET,
  BRIDGE_SECRET,
  SUPABASE_FUNCTIONS_URL = "https://pchbznvjjmfcfjwrbmvj.supabase.co/functions/v1",
  POLL_MS = "3000",
} = process.env;

const missing = ["SPECTRUM_PROJECT_ID", "SPECTRUM_PROJECT_SECRET", "BRIDGE_SECRET"].filter((k) => !process.env[k]);
if (missing.length) {
  console.error(`Missing ${missing.join(", ")}. Copy .env.example to .env and fill it in.`);
  process.exit(1);
}

const base = SUPABASE_FUNCTIONS_URL.replace(/\/+$/, "");

// Phone numbers are personal data: log only the last 2 digits.
const mask = (phone) => (phone ? `…${String(phone).slice(-2)}` : "?");

async function call(route, body) {
  const res = await fetch(`${base}/messaging/${route}`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "x-bridge-secret": BRIDGE_SECRET },
    body: JSON.stringify(body ?? {}),
    signal: AbortSignal.timeout(45_000),
  });
  if (!res.ok) throw new Error(`messaging/${route} -> HTTP ${res.status}`);
  return res.json();
}

const app = await Spectrum({
  projectId: SPECTRUM_PROJECT_ID,
  projectSecret: SPECTRUM_PROJECT_SECRET,
  providers: [imessage.config()],
});
const im = imessage(app);
console.log("Ebb bridge connected to Photon. Functions:", base);

// ---------------------------------------------------------------------------
// Outbound: drain the queue
// ---------------------------------------------------------------------------
const dmCache = new Map(); // E.164 phone -> space

async function dmFor(phone) {
  let space = dmCache.get(phone);
  if (!space) {
    space = await im.space.create(phone);
    dmCache.set(phone, space);
  }
  return space;
}

let draining = false;
async function drainOutbox() {
  if (draining) return;
  draining = true;
  try {
    const { texts = [] } = await call("outbox");
    if (!texts.length) return;
    const ids = [];
    const errors = {};
    for (const t of texts) {
      try {
        const space = await dmFor(t.to_phone);
        await space.send(t.body);
        ids.push(t.id);
        console.log(`sent ${t.kind} #${t.id} to ${mask(t.to_phone)}`);
      } catch (err) {
        dmCache.delete(t.to_phone);
        errors[String(t.id)] = String(err?.message ?? err).slice(0, 300);
        console.error(`failed ${t.kind} #${t.id} to ${mask(t.to_phone)}:`, errors[String(t.id)]);
      }
    }
    await call("sent", { ids, errors });
  } catch (err) {
    console.error("outbox poll failed:", err?.message ?? err);
  } finally {
    draining = false;
  }
}

const timer = setInterval(drainOutbox, Number(POLL_MS) || 3000);
drainOutbox();

// ---------------------------------------------------------------------------
// Inbound: forward DMs, send the replies back
// ---------------------------------------------------------------------------
async function handle(space, message) {
  const from = message.sender?.id;
  const text = message.content?.text ?? "";
  if (!from || !text.trim()) return;
  console.log(`text from ${mask(from)}`);
  const { replies = [] } = await call("inbound", { from, text, message_id: message.id });
  for (const reply of replies) {
    await space.send(reply);
  }
}

async function listen() {
  for await (const [space, message] of app.messages) {
    if (message.direction === "outbound") continue; // our own sends echo back
    if (message.platform !== "imessage") continue;
    if (space.type && space.type !== "dm") continue; // ignore group chats
    if (message.content?.type !== "text") continue;
    // Don't block the stream on Gemini; one slow answer shouldn't stall others.
    handle(space, message).catch((err) => console.error("inbound failed:", err?.message ?? err));
  }
}

let stopping = false;
async function shutdown() {
  if (stopping) return;
  stopping = true;
  clearInterval(timer);
  console.log("Stopping bridge…");
  await app.stop().catch(() => {});
  process.exit(0);
}
process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);

await listen();
