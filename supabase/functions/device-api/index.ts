// device-api: the only server code the watch talks to.
//
// Contract with the watch firmware. Do not change without telling Teammate 1.
// Every call: header Authorization: Bearer <device token>
//
// GET  /functions/v1/device-api/poll?profile_version=3
//   -> { "commands": [ { "id": "…", "type": "start_calm" } ], "profile": null }
//      profile is filled in only when a newer approved version exists; it is
//      the approved profile JSON plus its "version" number.
//      Returned commands are marked delivered_at = now(), so each runs once.
//      Commands older than 60 seconds are never returned: the watch never sees
//      created_at, so a watch that was offline must not act on an old tap.
//
// POST /functions/v1/device-api/events
//   { "events": [ { "trigger": "teacher", "command_id": "…", "started_at": "…", "ended_at": "…", "noise_db": 62, "motion_score": 0.2 } ] }
//   -> { "saved": 1 }
//   What the watch actually sends (tested 2026-10-10):
//   - Two posts per session. Start: ended_at = null. End: same started_at, ended_at set.
//     Matched by (device_id, started_at): start inserts, end fills ended_at.
//   - command_id is null unless trigger = "teacher".
//   - noise_db and motion_score are null until those watch modules exist.
//   - Offline, several events arrive in one post; saved = how many were stored.
//   - Any 4xx reply makes the watch drop that batch, so a single bad event is
//     skipped (not counted) instead of failing the whole batch.
//
// POST /functions/v1/device-api/status
//   { "calm_active": true, "battery_pct": 82, "firmware_version": "0.3.0" }
//   -> { "ok": true }
//
// GET  /functions/v1/device-api/voice
//   -> { "clips": [ { "id": "…", "url": "<signed, 1 h>" } ] }
//      The parent-approved voice clips for this watch's child, from the private
//      voice-clips bucket. The watch downloads new ones and drops removed ones.
//
// GET  /functions/v1/device-api/scenes
//   -> { "week_start": "2026-10-05", "scenes": [ { "id": "space_rain", "video": "space", "sound": "rain" }, … ] }
//      The newest parent-approved weekly set that has started (up to 6, in
//      play order). Empty when none is approved yet: the watch then uses the
//      calm profile's theme and sound. Events may carry "scene_id" back.
//
// Adaptive Ebb additions (docs/adaptive-contract.md). All additive: older
// firmware ignores the new response fields and never sends the new ones.
//
// GET /poll also returns
//   "settings":   { "auto_motion", "auto_noise", "motion_k", "noise_k", "gps_enabled" }
//                 (null when the watch is not paired to a child)
//   "scene_pick": scene id from this week's approved set, chosen by Thompson
//                 sampling (adaptive.ts pickScene); null when there is no set.
//   If either lookup fails the poll still answers (that field is null),
//   because the commands in the reply are already claimed.
//
// POST /status may also carry
//   "agitation": 0.42, "tier": 1,
//   "samples": [ { "at", "motion", "noise_db", "motion_z", "noise_z", "agitation" } ]
//   -> devices.agitation / agitation_at / tier; samples (newest 60, each "at"
//      within 10 minutes of now, values clamped) -> sensor_samples.
//   Reply adds "samples_saved". Samples also refresh the outcome of sessions
//   that ended in the last 5 minutes (the after-window fills in late).
//
// POST /events items may also carry agitation_peak, tier (1-3),
//   child_feeling ("better" | "same" | "worse"), lat, lng, accuracy_m.
//   An item with ended_at gets its outcome computed (before/after/recovery).
//   lat/lng become one "calm" pin in locations, only when the parent has
//   turned GPS on. Invalid optional values are dropped, never fail the batch.
//
// POST /location  { "points": [ { "at", "lat", "lng", "accuracy_m" } ] }  (<= 20)
//   -> { "saved": n }, or 204 with no body when GPS is off / not paired
//      (points are dropped, not stored). Points older than 24 h, more than
//      10 min in the future, or exactly 0,0 (no fix) are skipped.
//
// Pairing (no Authorization header: the watch has no token yet)
// POST /functions/v1/device-api/pair/start   { "hardware_id": "…" }
//   -> { "code": "<20 chars>", "secret": "<64 hex>", "expires_in": 900 }
//      The watch shows code as a QR (never typed, so it is long enough that it
//      cannot be guessed). Only the watch knows secret. hardware_id is only a
//      label: anyone can send any value, so nothing trusts it.
// POST /functions/v1/device-api/pair/status  { "secret": "…", "want_token": true }
//   -> { "status": "waiting", "expires_in": 812 }
//    | { "status": "paired", "nickname": "Sam", "teachers": 1, "expires_in": 640, "token": "…" }
//    | { "status": "expired" }
//      token is only included when want_token is true; asking again issues a
//      new token and retires the old one (for a watch that lost the reply).
//
// Deployed with verify_jwt = false: the watch has no Supabase login, so this
// function checks the device token itself (SHA-256 hash lookup in devices).
// It uses the service role key, which bypasses RLS and never leaves Supabase.

import { createClient } from "npm:@supabase/supabase-js@2";
import { computeEventOutcome, pickScene } from "./adaptive.ts";

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { persistSession: false } },
);

const COMMAND_MAX_AGE_MS = 60_000;
const PAIRING_WINDOW_S = 15 * 60;
const TRIGGERS = new Set(["teacher", "motion", "noise", "child_tap"]);
const SCENE_ID_RE = /^[a-z0-9_]{1,40}$/;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

type Device = { id: string; child_id: string | null };

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function randomHex(bytes: number): string {
  const buf = crypto.getRandomValues(new Uint8Array(bytes));
  return Array.from(buf).map((b) => b.toString(16).padStart(2, "0")).join("");
}

// Unambiguous base32: no 0/O, 1/I/L. 20 chars ~ 100 bits.
const QR_ALPHABET = "23456789ABCDEFGHJKMNPQRSTUVWXYZ";
function randomQrCode(length = 20): string {
  const buf = crypto.getRandomValues(new Uint8Array(length));
  return Array.from(buf).map((b) => QR_ALPHABET[b % QR_ALPHABET.length]).join("");
}

function secondsLeft(expiresAt: string): number {
  return Math.max(0, Math.floor((Date.parse(expiresAt) - Date.now()) / 1000));
}

async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function authenticate(req: Request): Promise<Device | null> {
  const header = req.headers.get("Authorization") ?? "";
  const match = header.match(/^Bearer\s+(\S+)$/);
  if (!match) return null;
  const { data, error } = await supabase
    .from("devices")
    .select("id, child_id")
    .eq("token_hash", await sha256Hex(match[1]))
    .maybeSingle();
  if (error) throw error;
  return data;
}

function isoOrNull(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const t = Date.parse(value);
  return Number.isNaN(t) ? null : new Date(t).toISOString();
}

function numberOrNull(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

function clampedOrNull(value: unknown, min: number, max: number): number | null {
  const n = numberOrNull(value);
  return n === null ? null : Math.max(min, Math.min(max, n));
}

// A whole number in [min, max], else null (the column has a check constraint,
// and a rejected row would fail the whole batch).
function intInRange(value: unknown, min: number, max: number): number | null {
  const n = numberOrNull(value);
  return n !== null && Number.isInteger(n) && n >= min && n <= max ? n : null;
}

const FEELINGS = new Set(["better", "same", "worse"]);
const MAX_SAMPLES = 60;
const MAX_POINTS = 20;
const SAMPLE_SKEW_MS = 10 * 60_000;
const POINT_MAX_AGE_MS = 24 * 3_600_000;
const OUTCOME_REFRESH_MS = 5 * 60_000;

type Fix = { lat: number; lng: number; accuracy_m: number | null };

function fixOrNull(raw: Record<string, unknown>): Fix | null {
  const lat = numberOrNull(raw.lat);
  const lng = numberOrNull(raw.lng);
  if (lat === null || lng === null) return null;
  if (lat < -90 || lat > 90 || lng < -180 || lng > 180) return null;
  if (lat === 0 && lng === 0) return null;  // GPS modules report 0,0 before a fix
  return { lat, lng, accuracy_m: clampedOrNull(raw.accuracy_m, 0, 100_000) };
}

type Settings = {
  auto_motion: boolean;
  auto_noise: boolean;
  motion_k: number;
  noise_k: number;
  gps_enabled: boolean;
};

async function childSettings(childId: string): Promise<Settings | null> {
  const { data, error } = await supabase
    .from("child_settings")
    .select("auto_motion, auto_noise, motion_k, noise_k, gps_enabled")
    .eq("child_id", childId)
    .maybeSingle();
  if (error) throw error;
  return data;
}

async function gpsEnabled(childId: string): Promise<boolean> {
  return (await childSettings(childId))?.gps_enabled === true;
}

async function safeOutcome(eventId: string, deviceId: string): Promise<void> {
  try {
    await computeEventOutcome(supabase, eventId);
  } catch (err) {
    const e = err as { name?: string; code?: string };
    console.error("outcome failed", deviceId, e?.name ?? "Error", e?.code ?? "");
  }
}

async function poll(device: Device, url: URL): Promise<Response> {
  const since = new Date(Date.now() - COMMAND_MAX_AGE_MS).toISOString();

  // Claim pending commands and mark them delivered in one update, so two
  // overlapping polls can never both receive the same command.
  const { data: claimed, error } = await supabase
    .from("commands")
    .update({ delivered_at: new Date().toISOString() })
    .eq("device_id", device.id)
    .is("delivered_at", null)
    .gt("created_at", since)
    .select("id, type, created_at");
  if (error) throw error;

  const commands = (claimed ?? [])
    .sort((a, b) => a.created_at.localeCompare(b.created_at))
    .map(({ id, type }) => ({ id, type }));

  let profile: Record<string, unknown> | null = null;
  const have = Number.parseInt(url.searchParams.get("profile_version") ?? "0", 10) || 0;
  if (device.child_id) {
    const { data: latest, error: pErr } = await supabase
      .from("calm_profiles")
      .select("version, profile")
      .eq("child_id", device.child_id)
      .eq("status", "approved")
      .order("version", { ascending: false })
      .limit(1)
      .maybeSingle();
    if (pErr) throw pErr;
    if (latest && latest.version > have) {
      profile = { ...(latest.profile as Record<string, unknown>), version: latest.version };
    }
  }

  await supabase.from("devices").update({ last_seen_at: new Date().toISOString() }).eq("id", device.id);

  // The commands above are already claimed, so these extras must never turn
  // the reply into an error: on failure the field is just null.
  let settings: Settings | null = null;
  let scenePick: string | null = null;
  if (device.child_id) {
    const childId = device.child_id;
    const [s, p] = await Promise.allSettled([childSettings(childId), pickScene(supabase, childId)]);
    if (s.status === "fulfilled") settings = s.value;
    else console.error("poll settings failed", device.id);
    if (p.status === "fulfilled") scenePick = p.value;
    else console.error("poll scene_pick failed", device.id);
  }

  return json({ commands, profile, settings, scene_pick: scenePick });
}

async function events(device: Device, req: Request): Promise<Response> {
  let body: { events?: unknown };
  try {
    body = await req.json();
  } catch {
    return json({ error: "body must be JSON" }, 400);
  }
  if (!Array.isArray(body.events)) return json({ error: "events must be an array" }, 400);

  let saved = 0;
  let lastCalmActive: boolean | null = null;
  let gps: boolean | null = null;  // child_settings.gps_enabled, read once per batch

  for (const raw of body.events as Record<string, unknown>[]) {
    const trigger = raw?.trigger;
    const startedAt = isoOrNull(raw?.started_at);
    if (typeof trigger !== "string" || !TRIGGERS.has(trigger) || !startedAt) {
      console.warn("skipping invalid event", device.id);  // not the event itself: it is a child's data
      continue;
    }
    const endedAt = isoOrNull(raw.ended_at);

    // A teacher command only counts if it was sent to this device.
    let commandId: string | null = null;
    let startedBy: string | null = null;
    if (typeof raw.command_id === "string" && UUID_RE.test(raw.command_id)) {
      const { data: cmd } = await supabase
        .from("commands")
        .select("id, created_by")
        .eq("id", raw.command_id)
        .eq("device_id", device.id)
        .maybeSingle();
      if (cmd) {
        commandId = cmd.id;
        startedBy = cmd.created_by;
      }
    }

    const row: Record<string, unknown> = {
      device_id: device.id,
      child_id: device.child_id,
      trigger,
      command_id: commandId,
      started_by: startedBy,
      started_at: startedAt,
      noise_db: numberOrNull(raw.noise_db),
      motion_score: numberOrNull(raw.motion_score),
      scene_id: typeof raw.scene_id === "string" && SCENE_ID_RE.test(raw.scene_id) ? raw.scene_id : null,
    };
    // Adaptive fields: only set when sent, so an end report without them never
    // wipes what the start report stored.
    const peak = clampedOrNull(raw.agitation_peak, 0, 10);
    if (peak !== null) row.agitation_peak = peak;
    const tier = intInRange(raw.tier, 1, 3);
    if (tier !== null) row.tier = tier;
    if (typeof raw.child_feeling === "string" && FEELINGS.has(raw.child_feeling)) row.child_feeling = raw.child_feeling;

    const { error } = endedAt
      // End report: create the session if the start never arrived, else fill ended_at.
      ? await supabase.from("events").upsert({ ...row, ended_at: endedAt }, { onConflict: "device_id,started_at" })
      // Start report: never overwrite a session that already has its end.
      : await supabase.from("events").upsert(row, { onConflict: "device_id,started_at", ignoreDuplicates: true });
    if (error) throw error;

    if (endedAt && commandId) {
      await supabase.from("commands").update({ done_at: endedAt }).eq("id", commandId).is("done_at", null);
    }
    saved++;
    lastCalmActive = !endedAt;

    // Outcome and calm pin are extras: a failure is logged, the event stays saved.
    const fix = fixOrNull(raw);
    if (device.child_id && (endedAt || fix)) {
      try {
        const { data: ev, error: idErr } = await supabase
          .from("events")
          .select("id")
          .eq("device_id", device.id)
          .eq("started_at", startedAt)
          .maybeSingle();
        if (idErr) throw idErr;
        if (ev) {
          if (endedAt) await safeOutcome(ev.id, device.id);
          if (fix) {
            gps ??= await gpsEnabled(device.child_id);
            if (gps) {
              // One pin per session, even if the watch resends the report.
              const { count } = await supabase
                .from("locations")
                .select("id", { count: "exact", head: true })
                .eq("event_id", ev.id)
                .eq("kind", "calm");
              if (!count) {
                const { error: lErr } = await supabase.from("locations").insert({
                  child_id: device.child_id,
                  device_id: device.id,
                  event_id: ev.id,
                  at: startedAt,
                  ...fix,
                  kind: "calm",
                });
                if (lErr) throw lErr;
              }
            }
          }
        }
      } catch (err) {
        const e = err as { name?: string; code?: string };
        console.error("event extras failed", device.id, e?.name ?? "Error", e?.code ?? "");
      }
    }
  }

  if (lastCalmActive !== null) {
    await supabase
      .from("devices")
      .update({ calm_active: lastCalmActive, last_seen_at: new Date().toISOString() })
      .eq("id", device.id);
  }
  return json({ saved });
}

async function status(device: Device, req: Request): Promise<Response> {
  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ error: "body must be JSON" }, 400);
  }
  const update: Record<string, unknown> = { last_seen_at: new Date().toISOString() };
  if (typeof body.calm_active === "boolean") update.calm_active = body.calm_active;
  const battery = numberOrNull(body.battery_pct);
  if (battery !== null) update.battery_pct = Math.max(0, Math.min(100, Math.round(battery)));
  if (typeof body.firmware_version === "string") update.firmware_version = body.firmware_version.slice(0, 32);

  // Live agitation readings (samples only when paired to a child).
  const now = Date.now();
  const samples: Record<string, unknown>[] = [];
  if (device.child_id && Array.isArray(body.samples)) {
    for (const raw of body.samples as Record<string, unknown>[]) {
      if (!raw || typeof raw !== "object") continue;
      const at = isoOrNull(raw.at);
      if (!at || Math.abs(Date.parse(at) - now) > SAMPLE_SKEW_MS) continue;
      samples.push({
        child_id: device.child_id,
        device_id: device.id,
        at,
        motion: clampedOrNull(raw.motion, 0, 1),
        noise_db: clampedOrNull(raw.noise_db, 0, 160),
        motion_z: clampedOrNull(raw.motion_z, -100, 100),
        noise_z: clampedOrNull(raw.noise_z, -100, 100),
        agitation: clampedOrNull(raw.agitation, 0, 10),
      });
    }
    // Newest 60.
    samples.sort((a, b) => (a.at as string).localeCompare(b.at as string));
    samples.splice(0, Math.max(0, samples.length - MAX_SAMPLES));
  }

  const latestSample = samples.findLast((s) => s.agitation !== null);
  const agitation = clampedOrNull(body.agitation, 0, 10) ?? (latestSample?.agitation as number | undefined) ?? null;
  if (agitation !== null) {
    update.agitation = agitation;
    update.agitation_at = new Date(now).toISOString();
  }
  const tier = clampedOrNull(body.tier, 0, 3);
  if (tier !== null) update.tier = Math.round(tier);

  const { error } = await supabase.from("devices").update(update).eq("id", device.id);
  if (error) throw error;

  let samplesSaved = 0;
  if (samples.length) {
    const { error: sErr } = await supabase.from("sensor_samples").insert(samples);
    if (sErr) {
      // Telemetry: log and keep the ok reply, so old and new firmware behave alike.
      console.error("samples insert failed", device.id, sErr.code ?? "");
    } else {
      samplesSaved = samples.length;
      // A session's "after" window (and recovery) is only known once the
      // samples that follow its end arrive, so refresh recently ended ones.
      const { data: recent } = await supabase
        .from("events")
        .select("id")
        .eq("device_id", device.id)
        .gte("ended_at", new Date(now - OUTCOME_REFRESH_MS).toISOString())
        .limit(3);
      for (const ev of recent ?? []) await safeOutcome(ev.id, device.id);
    }
  }
  return json({ ok: true, samples_saved: samplesSaved });
}

async function location(device: Device, req: Request): Promise<Response> {
  const body = await readJson(req);
  if (!body || !Array.isArray(body.points)) return json({ error: "points must be an array" }, 400);
  // GPS off (or not paired): accept and drop, so the watch stops retrying.
  if (!device.child_id || !(await gpsEnabled(device.child_id))) return new Response(null, { status: 204 });

  const now = Date.now();
  const rows: Record<string, unknown>[] = [];
  for (const raw of (body.points as Record<string, unknown>[]).slice(0, MAX_POINTS)) {
    if (!raw || typeof raw !== "object") continue;
    const at = isoOrNull(raw.at);
    const fix = fixOrNull(raw);
    if (!at || !fix) continue;
    const t = Date.parse(at);
    if (t > now + SAMPLE_SKEW_MS || t < now - POINT_MAX_AGE_MS) continue;
    rows.push({ child_id: device.child_id, device_id: device.id, at, ...fix, kind: "trail" });
  }
  if (rows.length) {
    const { error } = await supabase.from("locations").insert(rows);
    if (error) throw error;
  }
  return json({ saved: rows.length });
}

async function voice(device: Device): Promise<Response> {
  if (!device.child_id) return json({ clips: [] });
  const { data: rows, error } = await supabase
    .from("voice_clips")
    .select("id, storage_path")
    .eq("child_id", device.child_id)
    .eq("status", "approved")
    .order("created_at");
  if (error) throw error;
  const clips = await Promise.all((rows ?? []).map(async (r) => {
    const { data } = await supabase.storage.from("voice-clips").createSignedUrl(r.storage_path, 3600);
    return { id: r.id, url: data?.signedUrl ?? null };
  }));
  return json({ clips: clips.filter((c) => c.url) });
}

async function scenes(device: Device): Promise<Response> {
  if (!device.child_id) return json({ week_start: null, scenes: [] });
  // "Today" in the school's time zone, so a new week starts Monday morning there.
  const today = new Date().toLocaleDateString("en-CA", { timeZone: "America/New_York" });
  const { data: set, error } = await supabase
    .from("scene_sets")
    .select("week_start, scene_set_items(position, scenes(id, video, sound))")
    .eq("child_id", device.child_id)
    .eq("status", "approved")
    .lte("week_start", today)
    .order("week_start", { ascending: false })
    .limit(1)
    .maybeSingle();
  if (error) throw error;
  if (!set) return json({ week_start: null, scenes: [] });
  type Item = { position: number; scenes: { id: string; video: string; sound: string } | null };
  const items = ((set.scene_set_items ?? []) as unknown as Item[])
    .filter((i) => i.scenes)
    .sort((a, b) => a.position - b.position)
    .map((i) => i.scenes!);
  return json({ week_start: set.week_start, scenes: items });
}

async function readJson(req: Request): Promise<Record<string, unknown> | null> {
  try {
    const body = await req.json();
    return body && typeof body === "object" ? body : null;
  } catch {
    return null;
  }
}

async function pairStart(req: Request): Promise<Response> {
  const body = await readJson(req);
  const hardwareId = typeof body?.hardware_id === "string" ? body.hardware_id.slice(0, 64) : null;

  const secret = randomHex(32);
  const qrCode = randomQrCode();
  const { error } = await supabase.from("pairing_sessions").insert({
    code: String(crypto.getRandomValues(new Uint32Array(1))[0] % 1_000_000).padStart(6, "0"),  // legacy column, unused
    qr_code: qrCode,
    secret_hash: await sha256Hex(secret),
    hardware_id: hardwareId,
    expires_at: new Date(Date.now() + PAIRING_WINDOW_S * 1000).toISOString(),
  });
  if (error) throw error;
  return json({ code: qrCode, secret, expires_in: PAIRING_WINDOW_S });
}

async function pairStatus(req: Request): Promise<Response> {
  const body = await readJson(req);
  if (typeof body?.secret !== "string") return json({ error: "secret required" }, 400);

  const { data: session, error } = await supabase
    .from("pairing_sessions")
    .select("id, hardware_id, child_id, device_id, expires_at")
    .eq("secret_hash", await sha256Hex(body.secret))
    .maybeSingle();
  if (error) throw error;

  const left = session ? secondsLeft(session.expires_at) : 0;
  if (!session || (!session.child_id && left === 0)) return json({ status: "expired" });
  if (!session.child_id) return json({ status: "waiting", expires_in: left });

  const { data: child } = await supabase.from("children").select("nickname").eq("id", session.child_id).single();
  const { count: teachers } = await supabase
    .from("child_members")
    .select("user_id", { count: "exact", head: true })
    .eq("child_id", session.child_id);
  const reply: Record<string, unknown> = {
    status: "paired",
    nickname: child?.nickname ?? "",
    teachers: teachers ?? 0,
    expires_in: left,
  };

  if (body.want_token === true && left > 0) {
    const token = randomHex(32);
    const tokenHash = await sha256Hex(token);
    if (!session.device_id) {
      // Same watch re-paired to the same child: retire its old row so the child
      // has one current watch for Start calm. Scoped to this child, because
      // hardware_id comes from an unauthenticated caller and must never let
      // one family unlink another family's watch.
      if (session.hardware_id) {
        await supabase
          .from("devices")
          .update({ child_id: null })
          .eq("hardware_id", session.hardware_id)
          .eq("child_id", session.child_id);
      }
      const { data: device, error: dErr } = await supabase
        .from("devices")
        .insert({ child_id: session.child_id, hardware_id: session.hardware_id, token_hash: tokenHash })
        .select("id")
        .single();
      if (dErr) throw dErr;
      await supabase
        .from("pairing_sessions")
        .update({ device_id: device.id, token_issued_at: new Date().toISOString() })
        .eq("id", session.id);
    } else {
      const { error: uErr } = await supabase.from("devices").update({ token_hash: tokenHash }).eq("id", session.device_id);
      if (uErr) throw uErr;
      await supabase.from("pairing_sessions").update({ token_issued_at: new Date().toISOString() }).eq("id", session.id);
    }
    reply.token = token;
  }
  return json(reply);
}

Deno.serve(async (req) => {
  const url = new URL(req.url);
  // Everything after ".../device-api/", e.g. "poll" or "pair/status".
  const route = url.pathname.replace(/\/+$/, "").split("/device-api/")[1] ?? "";

  try {
    if (route === "pair/start" && req.method === "POST") return await pairStart(req);
    if (route === "pair/status" && req.method === "POST") return await pairStatus(req);

    const device = await authenticate(req);
    if (!device) return json({ error: "unauthorized" }, 401);

    if (route === "poll" && req.method === "GET") return await poll(device, url);
    if (route === "events" && req.method === "POST") return await events(device, req);
    if (route === "status" && req.method === "POST") return await status(device, req);
    if (route === "location" && req.method === "POST") return await location(device, req);
    if (route === "voice" && req.method === "GET") return await voice(device);
    if (route === "scenes" && req.method === "GET") return await scenes(device);
    return json({ error: "not found" }, 404);
  } catch (err) {
    const e = err as { name?: string; code?: string };
    console.error("device-api failed", route, e?.name ?? "Error", e?.code ?? "");
    return json({ error: "server error" }, 500);
  }
});
