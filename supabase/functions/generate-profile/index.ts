// generate-profile: turns a parent's assessment answers into a calm profile
// with Gemini, and saves it as a draft for the parent to approve.
//
// POST /functions/v1/generate-profile   (called by the signed-in parent)
//   { "assessment_id": "…" }
//   -> { "id": "…", "version": 2, "status": "draft", "profile": { …CalmProfile } }
//
// Runs as the caller (their JWT), so RLS still decides what it can read and
// write: only the child's parent can read the assessment and create the draft.
// GEMINI_API_KEY lives only in Supabase function secrets. The child's
// nickname is never sent to Gemini; only the age band and the answers are.

import { createClient } from "npm:@supabase/supabase-js@2";
import { GEMINI_SCHEMA, sanitize, SYSTEM_PROMPT } from "./profile-schema.ts";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });
}

async function askGemini(ageBand: string, answers: Record<string, unknown>): Promise<Record<string, unknown>> {
  const key = Deno.env.get("GEMINI_API_KEY");
  if (!key) throw new HttpError(503, "AI is not set up yet (GEMINI_API_KEY missing)");
  const model = Deno.env.get("GEMINI_MODEL") ?? "gemini-2.5-flash";

  const res = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "x-goog-api-key": key },  // header, so the key never sits in a URL
    body: JSON.stringify({
      systemInstruction: { parts: [{ text: SYSTEM_PROMPT }] },
      contents: [{
        role: "user",
        parts: [{ text: `Age band: ${ageBand}\nAssessment answers (JSON):\n${JSON.stringify(answers, null, 2)}` }],
      }],
      generationConfig: {
        responseMimeType: "application/json",
        responseSchema: GEMINI_SCHEMA,
        temperature: 0.4,
      },
    }),
  });
  if (!res.ok) {
    // Status and size only: the body can echo the child's assessment answers.
    const detail = await res.text();
    console.error("gemini error", res.status, `${detail.length} bytes`);
    throw new HttpError(502, "The AI did not answer; try again");
  }
  const out = await res.json();
  const text = out?.candidates?.[0]?.content?.parts?.[0]?.text;
  try {
    return JSON.parse(text);
  } catch {
    console.error("gemini returned non-JSON", typeof text === "string" ? `${text.length} chars` : typeof text);
    throw new HttpError(502, "The AI answer was not usable; try again");
  }
}

class HttpError extends Error {
  constructor(public status: number, message: string) {
    super(message);
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "use POST" }, 405);

  const authorization = req.headers.get("Authorization");
  if (!authorization) return json({ error: "not signed in" }, 401);

  // A client that acts as the caller, so every query below goes through RLS.
  const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false },
  });

  try {
    const { data: userData } = await supabase.auth.getUser();
    if (!userData.user) return json({ error: "not signed in" }, 401);

    const body = await req.json().catch(() => ({}));
    if (typeof body.assessment_id !== "string") return json({ error: "assessment_id required" }, 400);

    const { data: assessment, error: aErr } = await supabase
      .from("assessments")
      .select("id, child_id, answers")
      .eq("id", body.assessment_id)
      .maybeSingle();
    if (aErr) throw aErr;
    if (!assessment) return json({ error: "assessment not found" }, 404);

    const { data: child, error: cErr } = await supabase
      .from("children")
      .select("id, age_band, owner_id")
      .eq("id", assessment.child_id)
      .single();
    if (cErr) throw cErr;
    if (child.owner_id !== userData.user.id) return json({ error: "only the parent can do this" }, 403);

    const answers = (assessment.answers ?? {}) as Record<string, unknown>;
    const profile = sanitize(await askGemini(child.age_band, answers), answers);

    const { data: latest } = await supabase
      .from("calm_profiles")
      .select("version")
      .eq("child_id", child.id)
      .order("version", { ascending: false })
      .limit(1)
      .maybeSingle();
    const version = (latest?.version ?? 0) + 1;

    const { data: saved, error: sErr } = await supabase
      .from("calm_profiles")
      .insert({ child_id: child.id, version, profile, model: Deno.env.get("GEMINI_MODEL") ?? "gemini-2.5-flash" })
      .select("id, version, status, profile")
      .single();
    if (sErr) throw sErr;
    return json(saved);
  } catch (err) {
    if (err instanceof HttpError) return json({ error: err.message }, err.status);
    // Name and code only; a Postgres error message can quote the row it rejected.
    const e = err as { name?: string; code?: string };
    console.error("generate-profile failed", e?.name ?? "Error", e?.code ?? "");
    return json({ error: "server error" }, 500);
  }
});
