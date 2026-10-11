// Adaptive Ebb helpers for device-api, in TypeScript because the private
// schema (where the SQL versions live) is not exposed through PostgREST.
// Each function mirrors its SQL twin in migrations 0018b / 0019; keep the two
// in step if either changes.
//
//   pickScene            <-> private.pick_scene + private.scene_counts
//                            + private.event_success + private.beta_sample
//   computeEventOutcome  <-> private.compute_event_outcome

import type { SupabaseClient } from "npm:@supabase/supabase-js@2";

const TZ = "America/New_York";
const DAY_MS = 86_400_000;

// ---------------------------------------------------------------------------
// Time helpers
// ---------------------------------------------------------------------------

function nyHour(at: Date): number {
  const h = new Intl.DateTimeFormat("en-US", { timeZone: TZ, hour: "numeric", hourCycle: "h23" }).format(at);
  return Number.parseInt(h, 10) % 24;
}

// private.time_bucket
export function timeBucket(at: Date): "morning" | "afternoon" | "evening" {
  const h = nyHour(at);
  return h < 12 ? "morning" : h < 17 ? "afternoon" : "evening";
}

// (now() at time zone 'America/New_York')::date as YYYY-MM-DD
export function nyToday(now = new Date()): string {
  return now.toLocaleDateString("en-CA", { timeZone: TZ });
}

// ---------------------------------------------------------------------------
// Beta sampling (Thompson). The SQL draws the a-th order statistic of
// a + b - 1 uniforms with a and b capped at 60; that is exactly Beta(a, b)
// for whole a, b. Here: two Gamma draws (Marsaglia-Tsang), same caps.
// ---------------------------------------------------------------------------

function uniform01(): number {
  // (0, 1): never exactly 0, so log() is safe.
  let u = 0;
  while (u === 0) u = Math.random();
  return u;
}

function standardNormal(): number {
  // Box-Muller
  return Math.sqrt(-2 * Math.log(uniform01())) * Math.cos(2 * Math.PI * uniform01());
}

export function gammaSample(shape: number): number {
  if (shape < 1) {
    // Boost: Gamma(k) = Gamma(k + 1) * U^(1/k). Not needed for our counts (>= 1).
    return gammaSample(shape + 1) * Math.pow(uniform01(), 1 / shape);
  }
  const d = shape - 1 / 3;
  const c = 1 / Math.sqrt(9 * d);
  for (;;) {
    const x = standardNormal();
    const v0 = 1 + c * x;
    if (v0 <= 0) continue;
    const v = v0 * v0 * v0;
    const u = uniform01();
    if (Math.log(u) < 0.5 * x * x + d - d * v + d * Math.log(v)) return d * v;
  }
}

export function betaSample(a: number, b: number): number {
  const x = gammaSample(Math.max(1, Math.min(a, 60)));
  const y = gammaSample(Math.max(1, Math.min(b, 60)));
  return x / (x + y);
}

// private.event_success: teacher rating, else the child's check-in, else a
// measured drop of at least 40% from a real (> 0.3) starting level.
export function eventSuccess(
  helped: boolean | null,
  feeling: string | null,
  before: number | null,
  after: number | null,
): boolean | null {
  if (helped !== null && helped !== undefined) return helped;
  if (feeling === "better") return true;
  if (feeling === "worse") return false;
  if (before !== null && before !== undefined && after !== null && after !== undefined && before > 0.3) {
    return after <= before * 0.6;
  }
  return null;
}

type Counts = { helped: number; not_helped: number };

// private.pick_scene: Thompson draw over this week's approved set, using the
// current time bucket's counts unless it has fewer than 2, then all-day.
export async function pickScene(db: SupabaseClient, childId: string, now = new Date()): Promise<string | null> {
  const today = nyToday(now);

  // Newest approved set that has started. pick_scene uses every item of that
  // set; scene_sets is unique on (child_id, week_start), so one set.
  const { data: set, error: sErr } = await db
    .from("scene_sets")
    .select("id, scene_set_items(position, scene_id)")
    .eq("child_id", childId)
    .eq("status", "approved")
    .lte("week_start", today)
    .order("week_start", { ascending: false })
    .limit(1)
    .maybeSingle();
  if (sErr) throw sErr;
  if (!set) return null;
  type Item = { position: number; scene_id: string };
  const sceneIds = ((set.scene_set_items ?? []) as Item[])
    .sort((a, b) => a.position - b.position)
    .map((i) => i.scene_id);
  if (sceneIds.length === 0) return null;

  // private.scene_counts inputs: 8 weeks, not false alarms, these scenes.
  const since = new Date(now.getTime() - 56 * DAY_MS).toISOString();
  const { data: rows, error: eErr } = await db
    .from("events")
    .select("scene_id, started_at, helped, child_feeling, agitation_before, agitation_after, false_alarm")
    .eq("child_id", childId)
    .in("scene_id", sceneIds)
    .gt("started_at", since)
    .or("false_alarm.is.null,false_alarm.eq.false");
  if (eErr) throw eErr;

  const bucket = timeBucket(now);
  const all = new Map<string, Counts>();
  const inBucket = new Map<string, Counts>();
  for (const id of sceneIds) {
    all.set(id, { helped: 0, not_helped: 0 });
    inBucket.set(id, { helped: 0, not_helped: 0 });
  }
  for (const r of rows ?? []) {
    const s = eventSuccess(r.helped, r.child_feeling, r.agitation_before, r.agitation_after);
    if (s === null) continue;
    const key = s ? "helped" : "not_helped";
    all.get(r.scene_id)![key]++;
    if (timeBucket(new Date(r.started_at)) === bucket) inBucket.get(r.scene_id)![key]++;
  }

  let best: string | null = null;
  let bestP = -1;
  for (const id of sceneIds) {
    let c = inBucket.get(id)!;
    if (c.helped + c.not_helped < 2) c = all.get(id)!;
    const p = betaSample(1 + c.helped, 1 + c.not_helped);
    if (p > bestP) {
      bestP = p;
      best = id;
    }
  }
  return best;
}

// ---------------------------------------------------------------------------
// Event outcome (private.compute_event_outcome)
// ---------------------------------------------------------------------------

type Sample = { at: string; agitation: number | null };

async function samplesBetween(db: SupabaseClient, childId: string, from: string, to: string): Promise<Sample[]> {
  // Paged: PostgREST caps a response (1000 rows by default) and a long
  // session at one sample per ~5 s can exceed that.
  const out: Sample[] = [];
  const PAGE = 1000;
  for (let offset = 0; offset < 20 * PAGE; offset += PAGE) {
    const { data, error } = await db
      .from("sensor_samples")
      .select("at, agitation")
      .eq("child_id", childId)
      .gte("at", from)
      .lte("at", to)
      .order("at", { ascending: true })
      .order("id", { ascending: true })
      .range(offset, offset + PAGE - 1);
    if (error) throw error;
    out.push(...((data ?? []) as Sample[]));
    if (!data || data.length < PAGE) break;
  }
  return out;
}

function mean(xs: number[]): number | null {
  return xs.length ? xs.reduce((s, x) => s + x, 0) / xs.length : null;
}

export async function computeEventOutcome(db: SupabaseClient, eventId: string): Promise<void> {
  const { data: e, error } = await db
    .from("events")
    .select("id, child_id, started_at, ended_at, agitation_peak")
    .eq("id", eventId)
    .maybeSingle();
  if (error) throw error;
  if (!e || !e.ended_at || !e.child_id) return;

  const start = Date.parse(e.started_at);
  const end = Date.parse(e.ended_at);
  const samples = await samplesBetween(
    db,
    e.child_id,
    new Date(Math.min(start, end) - 60_000).toISOString(),
    new Date(Math.max(start, end) + 120_000).toISOString(),
  );

  // avg / max / < ignore nulls, as in SQL.
  const valued = samples
    .filter((s) => typeof s.agitation === "number")
    .map((s) => ({ t: Date.parse(s.at), a: s.agitation as number }));

  const before = mean(valued.filter((s) => s.t >= start - 60_000 && s.t <= start).map((s) => s.a));
  const after = mean(valued.filter((s) => s.t >= end && s.t <= end + 60_000).map((s) => s.a));
  const peakWindow = valued.filter((s) => s.t >= start - 60_000 && s.t <= end).map((s) => s.a);
  const measuredPeak = peakWindow.length ? Math.max(...peakWindow) : null;
  const firstCalm = valued.find((s) => s.t > start && s.t <= end + 120_000 && s.a < 0.5);

  const { error: uErr } = await db
    .from("events")
    .update({
      agitation_before: before,
      agitation_after: after,
      agitation_peak: e.agitation_peak ?? measuredPeak,
      recovery_seconds: firstCalm ? Math.round((firstCalm.t - start) / 1000) : null,
    })
    .eq("id", eventId);
  if (uErr) throw uErr;
}
