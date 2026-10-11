// insights: a weekly AI report on one child's calm moments, for the app and
// website. See docs/adaptive-contract.md.
//
// POST /functions/v1/insights   (signed-in parent or linked teacher; verify_jwt on)
//   { "child_id": "…" }
//   -> the weekly_insights row: { id, child_id, week_start, stats, report, model, created_by, created_at }
//      report = { headline, patterns[], what_helps[], suggestions[], risk_windows[{ day, from, to, why }] }
//      Errors: 400 bad input, 401 not signed in, 404 no access, 502 the AI failed,
//      503 GEMINI_API_KEY missing. Calling again in the same week replaces the row.
//
// Everything is read with the caller's JWT, so RLS and the RPCs' own access
// checks decide what can be seen. Only the weekly_insights upsert uses the
// service role (the table has no insert policy).
//
// Privacy: Gemini gets numbers, scene ids, times and journal text. The child's
// nickname is replaced by "the child" and the names of the adults linked to
// the child by "an adult"; no ids, emails or names are sent.

import { createClient } from "npm:@supabase/supabase-js@2";

const MODEL = Deno.env.get("GEMINI_MODEL") ?? "gemini-3.5-flash-lite";
const TZ = "America/New_York";
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const DAYS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"] as const;

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });
}

class HttpError extends Error {
  constructor(public status: number, message: string) {
    super(message);
  }
}

// ---------------------------------------------------------------------------
// Time helpers (school time zone)
// ---------------------------------------------------------------------------

function nyParts(at: Date): { date: string; dow: string; time: string } {
  const f = new Intl.DateTimeFormat("en-US", {
    timeZone: TZ, weekday: "short", year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", hourCycle: "h23",
  });
  const p = Object.fromEntries(f.formatToParts(at).map((x) => [x.type, x.value]));
  return { date: `${p.year}-${p.month}-${p.day}`, dow: p.weekday, time: `${p.hour}:${p.minute}` };
}

// Monday of the current week in New York, YYYY-MM-DD (same as
// date_trunc('week', now() at time zone 'America/New_York')).
function weekStart(now = new Date()): string {
  const { date, dow } = nyParts(now);
  const back = DAYS.indexOf(dow as (typeof DAYS)[number]);
  const d = new Date(`${date}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() - Math.max(0, back));
  return d.toISOString().slice(0, 10);
}

// ---------------------------------------------------------------------------
// Name scrubbing
// ---------------------------------------------------------------------------

function escapeRe(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function makeScrubber(nickname: string | null, adultNames: string[]): (text: string) => string {
  const rules: [RegExp, string][] = [];
  const add = (name: string | null | undefined, replacement: string) => {
    const n = (name ?? "").trim();
    if (n.length < 2) return;
    // Whole name, then each part of a multi-word name ("Ms Rivera" -> "Rivera").
    const parts = [n, ...n.split(/\s+/).filter((w) => w.length >= 3)];
    for (const p of parts) rules.push([new RegExp(`(?<![\\p{L}\\p{N}])${escapeRe(p)}(?![\\p{L}\\p{N}])`, "giu"), replacement]);
  };
  add(nickname, "the child");
  for (const a of adultNames) add(a, "an adult");
  return (text: string) => rules.reduce((t, [re, rep]) => t.replace(re, rep), text);
}

// ---------------------------------------------------------------------------
// Gemini
// ---------------------------------------------------------------------------

const SYSTEM_PROMPT = `You help a parent and teachers of a special-needs student understand the
student's calm moments from a calming smartwatch. A "calm moment" is a session of calm mode on the
watch, started by a teacher, by the child, or automatically when motion or noise rose above the
child's own baseline. Agitation is 0..1+ where 1 is the auto-start line.

Write for a parent and a teacher: warm, plain English, short sentences, no jargon, no diagnosis,
no medical advice, never blame the child. Base every statement on the data given; if there is little
data say so in the headline and keep lists short. Refer to the student only as "the child".

Fields:
- headline: one sentence summary of the week.
- patterns: up to 5 observations (times of day, weekdays, triggers, how long sessions last).
- what_helps: up to 5 things that seem to help (scenes, times, teacher notes), with how sure we are.
- suggestions: up to 5 practical, gentle ideas for adults to try next week.
- risk_windows: up to 5 upcoming times worth watching, day as Mon..Sun, from/to as HH:MM (24h,
  school time zone), why in one short sentence.`;

const GEMINI_SCHEMA = {
  type: "OBJECT",
  properties: {
    headline: { type: "STRING" },
    patterns: { type: "ARRAY", items: { type: "STRING" } },
    what_helps: { type: "ARRAY", items: { type: "STRING" } },
    suggestions: { type: "ARRAY", items: { type: "STRING" } },
    risk_windows: {
      type: "ARRAY",
      items: {
        type: "OBJECT",
        properties: {
          day: { type: "STRING", enum: [...DAYS] },
          from: { type: "STRING" },
          to: { type: "STRING" },
          why: { type: "STRING" },
        },
        required: ["day", "from", "to", "why"],
        propertyOrdering: ["day", "from", "to", "why"],
      },
    },
  },
  required: ["headline", "patterns", "what_helps", "suggestions", "risk_windows"],
  propertyOrdering: ["headline", "patterns", "what_helps", "suggestions", "risk_windows"],
};

type Report = {
  headline: string;
  patterns: string[];
  what_helps: string[];
  suggestions: string[];
  risk_windows: { day: string; from: string; to: string; why: string }[];
};

const HHMM = /^([01]\d|2[0-3]):[0-5]\d$/;

function cleanText(v: unknown, max: number): string {
  return typeof v === "string" ? v.replace(/\s+/g, " ").trim().slice(0, max) : "";
}

function cleanList(v: unknown): string[] {
  return Array.isArray(v) ? v.map((x) => cleanText(x, 300)).filter(Boolean).slice(0, 5) : [];
}

function hhmm(v: unknown): string | null {
  if (typeof v !== "string") return null;
  const m = v.trim().match(/^(\d{1,2}):(\d{2})/);
  if (!m) return null;
  const s = `${m[1].padStart(2, "0")}:${m[2]}`;
  return HHMM.test(s) ? s : null;
}

function sanitize(raw: Record<string, unknown>, scrub: (t: string) => string): Report {
  const windows = Array.isArray(raw.risk_windows) ? raw.risk_windows : [];
  return {
    headline: scrub(cleanText(raw.headline, 300)) || "Not enough data yet for a clear picture this week.",
    patterns: cleanList(raw.patterns).map(scrub),
    what_helps: cleanList(raw.what_helps).map(scrub),
    suggestions: cleanList(raw.suggestions).map(scrub),
    risk_windows: windows
      .map((w: Record<string, unknown>) => ({
        day: DAYS.includes(w?.day as (typeof DAYS)[number]) ? (w.day as string) : null,
        from: hhmm(w?.from),
        to: hhmm(w?.to),
        why: scrub(cleanText(w?.why, 200)),
      }))
      .filter((w): w is Report["risk_windows"][number] => !!(w.day && w.from && w.to))
      .slice(0, 5),
  };
}

async function askGemini(payload: unknown): Promise<Record<string, unknown>> {
  const key = Deno.env.get("GEMINI_API_KEY");
  if (!key) throw new HttpError(503, "AI is not set up yet (GEMINI_API_KEY missing)");

  let res: Response;
  try {
    res = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:generateContent`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "x-goog-api-key": key },
      body: JSON.stringify({
        systemInstruction: { parts: [{ text: SYSTEM_PROMPT }] },
        contents: [{ role: "user", parts: [{ text: `Data for the last weeks (JSON):\n${JSON.stringify(payload)}` }] }],
        generationConfig: { responseMimeType: "application/json", responseSchema: GEMINI_SCHEMA, temperature: 0.4 },
      }),
      signal: AbortSignal.timeout(60_000),
    });
  } catch (err) {
    console.error("gemini unreachable", (err as Error)?.name ?? "Error");
    throw new HttpError(502, "The AI did not answer; try again");
  }
  if (!res.ok) {
    // Status and size only: the body can echo the journal text.
    const detail = await res.text();
    console.error("gemini error", res.status, `${detail.length} bytes`);
    throw new HttpError(502, "The AI did not answer; try again");
  }
  const out = await res.json().catch(() => null);
  const text = out?.candidates?.[0]?.content?.parts?.[0]?.text;
  try {
    const parsed = JSON.parse(text);
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) throw new Error("not an object");
    return parsed;
  } catch {
    console.error("gemini returned non-JSON", typeof text === "string" ? `${text.length} chars` : typeof text);
    throw new HttpError(502, "The AI answer was not usable; try again");
  }
}

// ---------------------------------------------------------------------------
// Handler
// ---------------------------------------------------------------------------

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "use POST" }, 405);

  const authorization = req.headers.get("Authorization");
  if (!authorization) return json({ error: "not signed in" }, 401);

  const url = Deno.env.get("SUPABASE_URL")!;
  // Acts as the caller: every read below goes through RLS.
  const db = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false },
  });

  try {
    const { data: userData } = await db.auth.getUser();
    const user = userData?.user;
    if (!user) return json({ error: "not signed in" }, 401);

    const body = await req.json().catch(() => ({}));
    const childId = body?.child_id;
    if (typeof childId !== "string" || !UUID_RE.test(childId)) return json({ error: "child_id required" }, 400);

    // Access: RLS only returns the child to its parent and linked teachers.
    const { data: child, error: cErr } = await db
      .from("children")
      .select("id, nickname, age_band, owner_id")
      .eq("id", childId)
      .maybeSingle();
    if (cErr) throw cErr;
    if (!child) return json({ error: "child not found" }, 404);

    const since7 = new Date(Date.now() - 7 * 86_400_000).toISOString();
    const [pattern, scenes, forecast, events, journal, members] = await Promise.all([
      db.rpc("child_pattern_stats", { p_child_id: childId, p_days: 28 }),
      db.rpc("scene_stats", { p_child_id: childId }),
      db.rpc("risk_forecast", { p_child_id: childId, p_hours: 24 }),
      db.from("events")
        .select("trigger, started_at, ended_at, scene_id, helped, false_alarm, child_feeling, agitation_peak, agitation_before, agitation_after, recovery_seconds, tier")
        .eq("child_id", childId)
        .gte("started_at", since7)
        .order("started_at", { ascending: true })
        .limit(200),
      db.from("journal_entries")
        .select("kind, day, body, created_at, event_id")
        .eq("child_id", childId)
        .gte("created_at", since7)
        .order("created_at", { ascending: true })
        .limit(40),
      db.from("child_members").select("user_id").eq("child_id", childId),
    ]);
    for (const r of [pattern, scenes, forecast, events, journal]) if (r.error) throw r.error;

    // Names to scrub: the parent and every linked adult the caller can see.
    const adultIds = [child.owner_id, user.id, ...((members.data ?? []) as { user_id: string }[]).map((m) => m.user_id)];
    const { data: adults } = await db.from("profiles").select("display_name").in("id", [...new Set(adultIds)]);
    const scrub = makeScrubber(child.nickname, ((adults ?? []) as { display_name: string | null }[])
      .map((a) => a.display_name ?? "").filter(Boolean));

    type SceneRow = { scene_id: string; title: string; bucket: string; helped: number; not_helped: number; mean: number; low: number; high: number };
    const sceneRows = ((scenes.data ?? []) as SceneRow[]).filter((s) => s.helped + s.not_helped > 0);
    type ForecastRow = { hour_start: string; expected: number; risk: number; level: string };
    const forecastRows = ((forecast.data ?? []) as ForecastRow[]).map((f) => {
      const p = nyParts(new Date(f.hour_start));
      return { day: p.dow, hour: p.time, risk: Math.round(f.risk * 100) / 100, level: f.level };
    });

    type EventRow = {
      trigger: string; started_at: string; ended_at: string | null; scene_id: string | null;
      helped: boolean | null; false_alarm: boolean | null; child_feeling: string | null;
      agitation_peak: number | null; agitation_before: number | null; agitation_after: number | null;
      recovery_seconds: number | null; tier: number | null;
    };
    const round2 = (x: number | null) => (x === null ? null : Math.round(x * 100) / 100);
    const eventRows = ((events.data ?? []) as EventRow[]).map((e) => {
      const p = nyParts(new Date(e.started_at));
      return {
        day: p.dow,
        time: p.time,
        trigger: e.trigger,
        minutes: e.ended_at ? Math.round((Date.parse(e.ended_at) - Date.parse(e.started_at)) / 6000) / 10 : null,
        scene: e.scene_id,
        helped: e.helped,
        false_alarm: e.false_alarm,
        child_feeling: e.child_feeling,
        tier: e.tier,
        agitation_peak: round2(e.agitation_peak),
        agitation_before: round2(e.agitation_before),
        agitation_after: round2(e.agitation_after),
        recovery_seconds: e.recovery_seconds,
      };
    });
    type JournalRow = { kind: string; day: string | null; body: string; created_at: string };
    const notes = ((journal.data ?? []) as JournalRow[]).map((j) => {
      const p = nyParts(new Date(j.created_at));
      return { kind: j.kind, day: j.day ?? p.date, text: scrub(j.body.slice(0, 1500)) };
    });

    const payload = {
      age_band: child.age_band,
      pattern_stats_28_days: pattern.data,
      scene_effectiveness: sceneRows.map((s) => ({
        scene: s.scene_id, title: s.title, bucket: s.bucket, helped: s.helped, not_helped: s.not_helped,
        mean: round2(s.mean), low: round2(s.low), high: round2(s.high),
      })),
      risk_next_24h: forecastRows,
      calm_moments_last_7_days: eventRows,
      teacher_notes_last_7_days: notes,
    };

    const report = sanitize(await askGemini(payload), scrub);

    // Written with the service role: weekly_insights has no insert policy.
    const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
    const { data: row, error: wErr } = await admin
      .from("weekly_insights")
      .upsert({
        child_id: childId,
        week_start: weekStart(),
        stats: {
          pattern: pattern.data,
          scenes: sceneRows,
          forecast: forecast.data ?? [],
          events_7d: eventRows.length,
          notes_7d: notes.length,
        },
        report,
        model: MODEL,
        created_by: user.id,
        created_at: new Date().toISOString(),
      }, { onConflict: "child_id,week_start" })
      .select("id, child_id, week_start, stats, report, model, created_by, created_at")
      .single();
    if (wErr) throw wErr;
    return json(row);
  } catch (err) {
    if (err instanceof HttpError) return json({ error: err.message }, err.status);
    // Name and code only; a Postgres error message can quote the row it rejected.
    const e = err as { name?: string; code?: string };
    console.error("insights failed", e?.name ?? "Error", e?.code ?? "");
    return json({ error: "server error" }, 500);
  }
});
