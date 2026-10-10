// Checks the device token; poll, events and status endpoints.
// TODO: Teammate 2 builds this.
//
// Contract with the watch firmware. Do not change without telling Teammate 1.
// Every call: header Authorization: Bearer <device token>
//
// GET  /functions/v1/device-api/poll?profile_version=3
//   -> { "commands": [ { "id": "…", "type": "start_calm" } ], "profile": null }
//      profile filled in only when a newer approved version exists.
//      Marks returned commands delivered_at = now(), so each runs once.
//      Commands older than 60 seconds are dropped HERE: the watch never sees created_at.
//
// POST /functions/v1/device-api/events
//   { "events": [ { "trigger": "teacher", "command_id": "…", "started_at": "…", "ended_at": "…", "noise_db": 62, "motion_score": 0.2 } ] }
//   -> { "saved": 1 }
//   What the watch actually sends (tested 2026-10-10):
//   - Two posts per session. Start: ended_at = null. End: same started_at, ended_at set.
//     Match them by (device_id, started_at): insert on start, update ended_at on end.
//   - command_id is null unless trigger = "teacher".
//   - noise_db and motion_score are null until those watch modules exist.
//   - Offline, several events arrive in one post; reply saved = how many were stored.
//   - Any 4xx reply makes the watch drop that batch; only use 4xx for truly bad data.
//
// POST /functions/v1/device-api/status
//   { "calm_active": true, "battery_pct": 82, "firmware_version": "0.3.0" }
//   -> { "ok": true }

export {};
