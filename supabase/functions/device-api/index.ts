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
// Deployed with verify_jwt = false: the watch has no Supabase login, so this
// function checks the device token itself (SHA-256 hash lookup in devices).
// It uses the service role key, which bypasses RLS and never leaves Supabase.

import { createClient } from "npm:@supabase/supabase-js@2";

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { persistSession: false } },
);

const COMMAND_MAX_AGE_MS = 60_000;
const TRIGGERS = new Set(["teacher", "motion", "noise", "child_tap"]);
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

type Device = { id: string; child_id: string | null };

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
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

  return json({ commands, profile });
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

  for (const raw of body.events as Record<string, unknown>[]) {
    const trigger = raw?.trigger;
    const startedAt = isoOrNull(raw?.started_at);
    if (typeof trigger !== "string" || !TRIGGERS.has(trigger) || !startedAt) {
      console.warn("skipping invalid event", raw);
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

    const row = {
      device_id: device.id,
      child_id: device.child_id,
      trigger,
      command_id: commandId,
      started_by: startedBy,
      started_at: startedAt,
      noise_db: numberOrNull(raw.noise_db),
      motion_score: numberOrNull(raw.motion_score),
    };

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

  const { error } = await supabase.from("devices").update(update).eq("id", device.id);
  if (error) throw error;
  return json({ ok: true });
}

Deno.serve(async (req) => {
  const url = new URL(req.url);
  const route = url.pathname.replace(/\/+$/, "").split("/").pop();

  try {
    const device = await authenticate(req);
    if (!device) return json({ error: "unauthorized" }, 401);

    if (route === "poll" && req.method === "GET") return await poll(device, url);
    if (route === "events" && req.method === "POST") return await events(device, req);
    if (route === "status" && req.method === "POST") return await status(device, req);
    return json({ error: "not found" }, 404);
  } catch (err) {
    console.error(err);
    return json({ error: "server error" }, 500);
  }
});
