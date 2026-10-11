// messaging: the server side of Ebb's iMessage line (Photon). The bridge on
// the Mac (photon-bridge/) is the only caller; it authenticates with the
// x-bridge-secret header (BRIDGE_SECRET). verify_jwt is off.
//
// POST /functions/v1/messaging/outbox
//   -> { texts: [{ id, to_phone, body, kind }] }    up to 20 texts, claimed for sending
// POST /functions/v1/messaging/sent      { ids: [1, 2], errors: { "3": "why" } }
//   -> { ok: true }
// POST /functions/v1/messaging/inbound   { from: "+15551234567", text, message_id }
//   -> { replies: ["…"] }                           the bridge sends these back
//
// Inbound texts from a confirmed phone are either a question about a child
// (answered by Gemini from that child's data, limited to what the texter can
// see in the app), a note (saved to the child's journal; a trigger texts it to
// the other adults), or a request to start/stop calm (app/watch only).
// The child's nickname is never sent to Gemini: it becomes "[child]" and is
// put back into the answer here.

import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";

const MODEL = Deno.env.get("GEMINI_MODEL") ?? "gemini-3.5-flash-lite";
const MAX_REPLY = 600;

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

async function sha256(s: string): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s)));
}

// Constant-time: compare fixed-length digests byte by byte without early exit.
async function secretMatches(given: string | null): Promise<boolean> {
  const expected = Deno.env.get("BRIDGE_SECRET") ?? "";
  if (expected.length < 16 || !given) return false;
  const [a, b] = await Promise.all([sha256(given), sha256(expected)]);
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

// ---------------------------------------------------------------------------
// Gemini
// ---------------------------------------------------------------------------
async function gemini(system: string, user: string, schema: Record<string, unknown>, temperature: number) {
  const key = Deno.env.get("GEMINI_API_KEY");
  if (!key) throw new Error("GEMINI_API_KEY missing");
  const res = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:generateContent`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "x-goog-api-key": key },
    body: JSON.stringify({
      systemInstruction: { parts: [{ text: system }] },
      contents: [{ role: "user", parts: [{ text: user }] }],
      generationConfig: { responseMimeType: "application/json", responseSchema: schema, temperature },
    }),
    signal: AbortSignal.timeout(20_000),
  });
  if (!res.ok) {
    const detail = await res.text();
    console.error("gemini error", res.status, `${detail.length} bytes`);
    throw new Error("gemini failed");
  }
  const out = await res.json();
  const text = out?.candidates?.[0]?.content?.parts?.[0]?.text;
  return JSON.parse(text);
}

type Intent = "question" | "note" | "calm_control" | "other";

const CLASSIFY_PROMPT = `You sort text messages that a parent or teacher sends to Ebb, a calming smartwatch service for a child with special needs. The child is written as [child].
Pick one intent:
- "question": they want information about [child] (how the day/week went, how many calm moments, what helps, what time things happen, what someone wrote).
- "note": they are telling the other adults something to remember or pass on (what happened, how [child] slept, a change at home or school, a reply to another adult's message, thanks).
- "calm_control": they want the watch to start or stop a calm session right now.
- "other": greetings with nothing else, help requests about the service, or anything unclear.
If a message both shares information and asks something, choose "question" only when the main point is the question.`;

const CLASSIFY_SCHEMA = {
  type: "OBJECT",
  properties: { intent: { type: "STRING", enum: ["question", "note", "calm_control", "other"] } },
  required: ["intent"],
};

const ANSWER_PROMPT = `You answer a parent's or teacher's text message about a child who wears Ebb, a calming smartwatch. The child is always written as [child]; write [child] whenever you mean the child, and never invent a name.
Use ONLY the JSON data provided. "Calm moments" are calm sessions on the watch; trigger "teacher" means an adult started it, "child_tap" the child asked for it, "motion"/"noise" the watch noticed rising agitation. Times are US Eastern.
Rules:
- Plain text for an iMessage: 1 to 3 short sentences, under 450 characters, no markdown, no lists, no emojis.
- Warm, calm and factual. Give specific numbers and times when they answer the question.
- If the data does not answer the question, say so briefly and suggest checking the Ebb app.
- No medical or diagnostic advice, no guesses about causes beyond what the data shows.
- You cannot start or stop calm sessions or change settings.`;

const ANSWER_SCHEMA = {
  type: "OBJECT",
  properties: { answer: { type: "STRING" } },
  required: ["answer"],
};

// ---------------------------------------------------------------------------
// Names
// ---------------------------------------------------------------------------
function escapeRe(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function nameRe(nickname: string): RegExp {
  return new RegExp(`(?<![\\p{L}\\p{N}])${escapeRe(nickname.trim())}(?![\\p{L}\\p{N}])`, "giu");
}

function hideName(text: string, nickname: string): string {
  return nickname.trim() ? text.replace(nameRe(nickname), "[child]") : text;
}

function hideNameDeep(value: unknown, nickname: string): unknown {
  if (typeof value === "string") return hideName(value, nickname);
  if (Array.isArray(value)) return value.map((v) => hideNameDeep(v, nickname));
  if (value && typeof value === "object") {
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(value)) {
      if (v === null) continue; // smaller prompt
      out[k] = hideNameDeep(v, nickname);
    }
    return out;
  }
  return value;
}

function clip(s: string, n = MAX_REPLY): string {
  return s.length <= n ? s : s.slice(0, n - 1).trimEnd() + "…";
}

// ---------------------------------------------------------------------------
// Inbound
// ---------------------------------------------------------------------------
type Child = { id: string; nickname: string; relation: "parent" | "teacher" };
type Texter = { user_id: string; display_name: string | null; role: string; children: Child[]; thread_child_id: string | null };

const NOT_LINKED = "This number isn't linked to Ebb yet. In the app: Account → Add phone.";
const CALM_ONLY_IN_APP =
  "Calm sessions can only be started or stopped from the Ebb app or on the watch, so the adult nearby stays in control.";

async function rpc<T>(db: SupabaseClient, fn: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await db.rpc(fn, args);
  if (error) {
    console.error(`rpc ${fn} failed`, error.code ?? "");
    throw new Error(`rpc ${fn} failed`);
  }
  return data as T;
}

function names(children: Child[]): string {
  const n = children.map((c) => c.nickname);
  return n.length <= 1 ? n.join("") : `${n.slice(0, -1).join(", ")} or ${n[n.length - 1]}`;
}

async function handleInbound(db: SupabaseClient, from: string, rawText: string, messageId: string): Promise<string[]> {
  const status = await rpc<string>(db, "ebb_text_begin_inbound", { p_message_id: messageId, p_phone: from });
  if (status === "duplicate") return [];
  if (status === "rate_limited") return ["That's a lot of messages at once. Please wait a little and try again."];

  const texter = await rpc<Texter | null>(db, "ebb_text_user", { p_phone: from });
  if (!texter) return [NOT_LINKED];
  if (texter.children.length === 0) {
    return ["Your number is linked, but no child is on your Ebb account yet. Add or join a child in the app first."];
  }

  let text = rawText.trim();
  let child: Child | undefined;

  // "Sam: how was today?" picks the child; a bare "Sam" just switches.
  for (const c of texter.children) {
    const re = new RegExp(`^\\s*${escapeRe(c.nickname.trim())}\\s*(?:[:,\\-–—]\\s*|$)`, "iu");
    if (re.test(text)) {
      child = c;
      text = text.replace(re, "").trim();
      break;
    }
  }
  if (child && !text) {
    await rpc(db, "ebb_text_set_thread", { p_phone: from, p_user: texter.user_id, p_child: child.id });
    return [`Got it, we're talking about ${child.nickname} now.`];
  }
  if (!child && texter.children.length === 1) child = texter.children[0];
  if (!child && texter.thread_child_id) child = texter.children.find((c) => c.id === texter.thread_child_id);
  if (!child) {
    return [`Which child is this about? Start your text with their name, like "${texter.children[0].nickname}: …" (${names(texter.children)}).`];
  }
  await rpc(db, "ebb_text_set_thread", { p_phone: from, p_user: texter.user_id, p_child: child.id });

  const nick = child.nickname;
  const hidden = hideName(text, nick).slice(0, 2000);

  let intent: Intent;
  if (/\b(start|stop|begin|end|turn\s+(on|off)|trigger|activate|cancel)\b[^.?!]{0,30}\bcalm/i.test(text)) {
    intent = "calm_control";
  } else {
    try {
      const out = await gemini(CLASSIFY_PROMPT, `Sender is the child's ${child.relation}.\nMessage: ${hidden}`, CLASSIFY_SCHEMA, 0);
      intent = (["question", "note", "calm_control", "other"] as const).includes(out?.intent) ? out.intent : "other";
    } catch {
      // AI down: a question we can't answer; anything else is kept as a note.
      intent = /\?\s*$/.test(text) ? "question" : "note";
      if (intent === "question") {
        return [`I can't look that up right now. Please try again in a few minutes, or check ${nick}'s page in the Ebb app.`];
      }
    }
  }

  if (intent === "calm_control") return [CALM_ONLY_IN_APP];

  if (intent === "other") {
    return [
      `Hi! Text me a question about ${nick} (like "How was today?") and I'll answer from Ebb's data, ` +
        `or text a note and I'll add it to ${nick}'s journal and pass it to the other adults.`,
    ];
  }

  if (intent === "note") {
    const saved = await rpc<{ saved: string; recipients?: number }>(db, "ebb_text_save_note", {
      p_user: texter.user_id,
      p_child: child.id,
      p_body: text.slice(0, 2000),
    });
    if (saved.saved === "relayed") {
      return [
        saved.recipients
          ? `Sent to ${nick}'s teachers. (No one has written in ${nick}'s journal today, so it isn't saved there.)`
          : `None of ${nick}'s teachers has a phone linked yet, so I couldn't pass that on. You can post it in the Ebb app.`,
      ];
    }
    return [`Added to ${nick}'s journal and shared with ${nick}'s team.`];
  }

  // Question.
  const context = await rpc<Record<string, unknown>>(db, "ebb_text_child_context", {
    p_user: texter.user_id,
    p_child: child.id,
  });
  const prompt = `Data (JSON):\n${JSON.stringify(hideNameDeep(context, nick))}\n\nMessage from the child's ${child.relation}: ${hidden}`;
  try {
    const out = await gemini(ANSWER_PROMPT, prompt, ANSWER_SCHEMA, 0.3);
    const answer = typeof out?.answer === "string" ? out.answer.trim() : "";
    if (!answer) throw new Error("empty answer");
    return [clip(answer.replace(/\[\s*child\s*\]/gi, nick))];
  } catch {
    return [`I can't look that up right now. Please try again in a few minutes, or check ${nick}'s page in the Ebb app.`];
  }
}

// ---------------------------------------------------------------------------
// Router
// ---------------------------------------------------------------------------
Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "use POST" }, 405);
  if (!(await secretMatches(req.headers.get("x-bridge-secret")))) return json({ error: "unauthorized" }, 401);

  const route = new URL(req.url).pathname.replace(/\/+$/, "").split("/").pop();
  const body = await req.json().catch(() => ({}));
  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false },
  });

  try {
    if (route === "outbox") {
      const texts = await rpc<unknown[]>(db, "ebb_text_claim_outbox", { p_limit: 20 });
      return json({ texts: texts ?? [] });
    }

    if (route === "sent") {
      const ids = Array.isArray(body.ids) ? body.ids.filter((n: unknown) => Number.isInteger(n)) : [];
      const errors: Record<string, string> = {};
      if (body.errors && typeof body.errors === "object") {
        for (const [k, v] of Object.entries(body.errors)) {
          if (/^\d+$/.test(k)) errors[k] = String(v).slice(0, 500);
        }
      }
      await rpc(db, "ebb_text_mark_sent", { p_ids: ids, p_errors: errors });
      return json({ ok: true });
    }

    if (route === "inbound") {
      const from = typeof body.from === "string" ? body.from : "";
      const text = typeof body.text === "string" ? body.text : "";
      const messageId = typeof body.message_id === "string" ? body.message_id.slice(0, 200) : "";
      if (!from || !messageId) return json({ error: "from and message_id required" }, 400);
      // Only a real phone number identifies a texter. iMessage handles can be
      // emails ("x+15551234567@icloud.com"), which must never map to a phone.
      if (!/^\+?[0-9 ()\-.]{7,24}$/.test(from.trim())) {
        return json({ replies: ["Please text Ebb from your phone number, not an email address."] });
      }
      if (!text.trim()) return json({ replies: [] });
      try {
        return json({ replies: await handleInbound(db, from, text, messageId) });
      } catch {
        return json({ replies: ["Sorry, something went wrong on our side. Please try again in a bit."] });
      }
    }

    return json({ error: "unknown route" }, 404);
  } catch (err) {
    // No phone numbers or message text in logs.
    console.error("messaging failed", route, (err as Error)?.message ?? "Error");
    return json({ error: "server error" }, 500);
  }
});
