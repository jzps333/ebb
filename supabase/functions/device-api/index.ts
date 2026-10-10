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
//
// POST /functions/v1/device-api/status
//   { "calm_active": true, "battery_pct": 82, "firmware_version": "0.3.0" }
//   -> { "ok": true }

export {};
