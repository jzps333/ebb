// voice: the parent's own voice, cloned with ElevenLabs, for calm phrases on
// their child's watch. Called by the signed-in parent from the iPhone app.
//
// POST ?action=clone&consent=1         body: the recording (audio/mp4, ~1 min)
//   -> { "ok": true }     The recording goes straight to ElevenLabs and is never
//                         stored; only the resulting voice id is kept.
// POST ?action=generate                { "child_id": "…", "phrases": ["You're safe.", …] }
//   -> { "clips": [ { id, phrase, status, url } ] }   new drafts, url = 1 h signed link
// GET  ?action=list&child_id=…         -> { "has_voice": true, "clips": [ … ] }
// POST ?action=delete_voice            -> { "ok": true }  removes the voice at
//                         ElevenLabs and every clip made from it
//
// Approving a clip is a plain RLS update from the app (voice_clips.status).
// Clips use eleven_v4 (newest), falling back to eleven_multilingual_v2.
// ELEVENLABS_API_KEY lives only in Supabase function secrets.

import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";

const ELEVEN = "https://api.elevenlabs.io/v1";
// Newest model first (best cloned-voice quality); if it rejects the request
// (e.g. a voice setting it does not take), fall back to the steady v2 model.
const TTS_MODELS = [Deno.env.get("ELEVENLABS_MODEL") ?? "eleven_v4", "eleven_multilingual_v2"];
const MAX_RECORDING_BYTES = 10 * 1024 * 1024;
const MAX_PHRASES = 8;
const SIGNED_URL_SECONDS = 3600;

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};

class HttpError extends Error {
  constructor(public status: number, message: string) {
    super(message);
  }
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });
}

function elevenKey(): string {
  const key = Deno.env.get("ELEVENLABS_API_KEY");
  if (!key) throw new HttpError(503, "Voice is not set up yet (ELEVENLABS_API_KEY missing)");
  return key;
}

// Turns an ElevenLabs failure into a message the parent can act on. Logs only
// the status and ElevenLabs' error code, never the request or audio.
async function elevenError(res: Response, what: string): Promise<never> {
  let code = "";
  try {
    const body = await res.json();
    code = typeof body?.detail?.status === "string" ? body.detail.status : "";
  } catch { /* not JSON */ }
  console.error("elevenlabs", what, res.status, code);
  if (res.status === 401) throw new HttpError(502, "The ElevenLabs key was rejected");
  if (code.includes("voice_clon") || code.includes("subscription") || res.status === 402) {
    throw new HttpError(402, "Your ElevenLabs plan does not include voice cloning (Starter or higher needed)");
  }
  if (code.includes("quota")) throw new HttpError(402, "Out of ElevenLabs credits");
  throw new HttpError(502, `ElevenLabs could not ${what}; try again`);
}

async function clone(req: Request, url: URL, uid: string, admin: SupabaseClient): Promise<Response> {
  if (url.searchParams.get("consent") !== "1") throw new HttpError(400, "consent is required");
  const audio = new Uint8Array(await req.arrayBuffer());
  if (audio.length < 20_000) throw new HttpError(400, "The recording is too short; read for about a minute");
  if (audio.length > MAX_RECORDING_BYTES) throw new HttpError(413, "The recording is too long");

  const form = new FormData();
  form.append("name", `Ebb parent ${uid.slice(0, 8)}`);
  form.append("description", "Parent's own voice for calming phrases on their child's Ebb watch (consented in app).");
  form.append("remove_background_noise", "true");
  form.append("files", new Blob([audio], { type: req.headers.get("content-type") ?? "audio/mp4" }), "recording.m4a");

  const res = await fetch(`${ELEVEN}/voices/add`, { method: "POST", headers: { "xi-api-key": elevenKey() }, body: form });
  if (!res.ok) await elevenError(res, "clone the voice");
  const { voice_id } = await res.json();

  // Replacing an earlier voice: remove the old one at ElevenLabs too.
  const { data: old } = await admin.from("parent_voices").select("elevenlabs_voice_id").eq("owner_id", uid).maybeSingle();
  const { error } = await admin.from("parent_voices").upsert({
    owner_id: uid,
    elevenlabs_voice_id: voice_id,
    consent_at: new Date().toISOString(),
  });
  if (error) throw error;
  if (old && old.elevenlabs_voice_id !== voice_id) {
    await fetch(`${ELEVEN}/voices/${old.elevenlabs_voice_id}`, { method: "DELETE", headers: { "xi-api-key": elevenKey() } });
  }
  return json({ ok: true });
}

async function signedClips(admin: SupabaseClient, rows: { id: string; phrase: string; status: string; storage_path: string }[]) {
  return await Promise.all(rows.map(async (r) => {
    const { data } = await admin.storage.from("voice-clips").createSignedUrl(r.storage_path, SIGNED_URL_SECONDS);
    return { id: r.id, phrase: r.phrase, status: r.status, url: data?.signedUrl ?? null };
  }));
}

async function ownChild(user: SupabaseClient, childId: unknown): Promise<string> {
  if (typeof childId !== "string") throw new HttpError(400, "child_id required");
  // RLS: a parent only sees their own children (teachers see linked ones, so check owner too).
  const { data } = await user.from("children").select("id, owner_id").eq("id", childId).maybeSingle();
  const { data: me } = await user.auth.getUser();
  if (!data || data.owner_id !== me.user?.id) throw new HttpError(403, "not your child");
  return data.id;
}

async function speak(voiceId: string, text: string): Promise<Uint8Array> {
  for (const [i, model] of TTS_MODELS.entries()) {
    const res = await fetch(`${ELEVEN}/text-to-speech/${voiceId}?output_format=mp3_22050_32`, {
      method: "POST",
      headers: { "xi-api-key": elevenKey(), "Content-Type": "application/json", Accept: "audio/mpeg" },
      body: JSON.stringify({
        text,
        model_id: model,
        // Calm delivery: steady, close to the parent's voice, no dramatic style, a bit slower.
        voice_settings: { stability: 0.8, similarity_boost: 0.85, style: 0, use_speaker_boost: true, speed: 0.85 },
      }),
    });
    if (res.ok) return new Uint8Array(await res.arrayBuffer());
    const last = i === TTS_MODELS.length - 1;
    // Only a rejected request (400/422) is worth retrying on the older model;
    // auth, plan and quota errors would fail the same way.
    if (last || (res.status !== 400 && res.status !== 422)) await elevenError(res, "make a clip");
    console.warn("elevenlabs model rejected, falling back", model, res.status);
  }
  throw new HttpError(502, "ElevenLabs could not make a clip; try again");
}

async function generate(req: Request, uid: string, user: SupabaseClient, admin: SupabaseClient): Promise<Response> {
  const body = await req.json().catch(() => ({}));
  const childId = await ownChild(user, body.child_id);
  const phrases = (Array.isArray(body.phrases) ? body.phrases : [])
    .filter((p: unknown): p is string => typeof p === "string")
    .map((p: string) => p.replace(/\s+/g, " ").trim())
    .filter((p: string) => p.length > 0 && p.length <= 80)
    .slice(0, MAX_PHRASES);
  if (!phrases.length) throw new HttpError(400, "Add at least one short phrase");

  const { data: voice } = await admin.from("parent_voices").select("elevenlabs_voice_id").eq("owner_id", uid).maybeSingle();
  if (!voice) throw new HttpError(409, "Record your voice first");

  // New drafts replace old drafts; approved clips stay until deleted.
  const { data: oldDrafts } = await admin.from("voice_clips").select("id, storage_path")
    .eq("child_id", childId).eq("owner_id", uid).eq("status", "draft");
  if (oldDrafts?.length) {
    await admin.storage.from("voice-clips").remove(oldDrafts.map((d) => d.storage_path));
    await admin.from("voice_clips").delete().in("id", oldDrafts.map((d) => d.id));
  }

  const made = [];
  for (const phrase of phrases) {
    const audio = await speak(voice.elevenlabs_voice_id, phrase);

    const id = crypto.randomUUID();
    const path = `${childId}/${id}.mp3`;
    const { error: upErr } = await admin.storage.from("voice-clips").upload(path, audio, { contentType: "audio/mpeg" });
    if (upErr) throw upErr;
    const { error: insErr } = await admin.from("voice_clips").insert({ id, child_id: childId, owner_id: uid, phrase, storage_path: path });
    if (insErr) throw insErr;
    made.push({ id, phrase, status: "draft", storage_path: path });
  }
  return json({ clips: await signedClips(admin, made) });
}

async function list(url: URL, uid: string, user: SupabaseClient, admin: SupabaseClient): Promise<Response> {
  const childId = await ownChild(user, url.searchParams.get("child_id"));
  const { data: voice } = await admin.from("parent_voices").select("owner_id").eq("owner_id", uid).maybeSingle();
  const { data: rows, error } = await admin.from("voice_clips").select("id, phrase, status, storage_path")
    .eq("child_id", childId).eq("owner_id", uid).order("created_at");
  if (error) throw error;
  return json({ has_voice: !!voice, clips: await signedClips(admin, rows ?? []) });
}

async function deleteVoice(uid: string, admin: SupabaseClient): Promise<Response> {
  const { data: voice } = await admin.from("parent_voices").select("elevenlabs_voice_id").eq("owner_id", uid).maybeSingle();
  if (voice) {
    await fetch(`${ELEVEN}/voices/${voice.elevenlabs_voice_id}`, { method: "DELETE", headers: { "xi-api-key": elevenKey() } });
  }
  const { data: clips } = await admin.from("voice_clips").select("id, storage_path").eq("owner_id", uid);
  if (clips?.length) {
    await admin.storage.from("voice-clips").remove(clips.map((c) => c.storage_path));
    await admin.from("voice_clips").delete().eq("owner_id", uid);
  }
  await admin.from("parent_voices").delete().eq("owner_id", uid);
  return json({ ok: true });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  const authorization = req.headers.get("Authorization");
  if (!authorization) return json({ error: "not signed in" }, 401);

  const user = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false },
  });
  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false },
  });

  try {
    const { data: me } = await user.auth.getUser();
    if (!me.user) return json({ error: "not signed in" }, 401);
    const { data: profile } = await user.from("profiles").select("role").eq("id", me.user.id).single();
    if (profile?.role !== "parent") return json({ error: "only a parent can set up their voice" }, 403);

    const url = new URL(req.url);
    const action = url.searchParams.get("action");
    if (action === "clone" && req.method === "POST") return await clone(req, url, me.user.id, admin);
    if (action === "generate" && req.method === "POST") return await generate(req, me.user.id, user, admin);
    if (action === "list" && req.method === "GET") return await list(url, me.user.id, user, admin);
    if (action === "delete_voice" && req.method === "POST") return await deleteVoice(me.user.id, admin);
    return json({ error: "unknown action" }, 404);
  } catch (err) {
    if (err instanceof HttpError) return json({ error: err.message }, err.status);
    const e = err as { name?: string; code?: string };
    console.error("voice failed", e?.name ?? "Error", e?.code ?? "");
    return json({ error: "server error" }, 500);
  }
});
