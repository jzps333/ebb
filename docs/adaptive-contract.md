# Adaptive Ebb: contract between watch, device-api, app and website

The watch senses rising agitation, responds in tiers, starts calm by itself,
measures the outcome, and the server learns per child. Schema lives in
`supabase/migrations/0018a…0019` (already applied to the live project).

## Loop

```
watch sensors ──► agitation (per-child z-scores) ──► tier 0-3 state machine
     │                                                   │
     │ POST /status samples every ~5 s                   │ tier 2 → start_calm("motion"/"noise")
     ▼                                                   ▼
sensor_samples ─► devices.agitation/tier (realtime) ─► app live graph + "rising" banner
events (+ agitation_peak, tier, child_feeling) ─► compute_event_outcome ─► before/after/recovery
teacher: helped / false_alarm ─► tune_sensitivity (motion_k / noise_k) ─► poll.settings ─► watch
helped / feeling / measured drop ─► event_success ─► Thompson sampling ─► poll.scene_pick ─► watch
events history ─► child_pattern_stats, risk_forecast, insights (Gemini) ─► app + website
```

## Watch signal processing (firmware)

- **Motion** (BMA423, ~25 Hz, read on the main loop): high-pass the acceleration
  magnitude (subtract a slow EWMA = gravity), keep a 128-sample window. Score =
  energy term × periodicity term, where periodicity = peak of normalized
  autocorrelation for lags 0.5–3 Hz (rocking / hand-flapping). Output 0..1.
- **Noise** (PDM mic, I2S port 0, 16 kHz, own FreeRTOS task): RMS of 100 ms
  frames → dBFS → approximate dB (`dBFS + 94` style offset, constant in config).
  Only the number is kept; audio is never stored or sent.
- **Baseline**: per-signal EWMA mean and variance (Welford-style, slow alpha,
  only updated while not agitated and not in calm mode), persisted to NVS every
  10 min, so it is the child's own normal. z = (x − mean) / max(std, floor).
- **Agitation** = max(motion_z / motion_k, noise_z / noise_k) for enabled
  signals, smoothed (EWMA ~3 s). 1.0 = the auto-start line.
- **Tiers** (hysteresis + dwell times, cooldown 2 min after a session):
  - 0 settled
  - 1 rising: agitation ≥ 0.6 for 5 s → slow haptic breathing cue on the wrist
  - 2 calm: agitation ≥ 1.0 for 10 s (motion) / 5 s (noise) → `start_calm("motion"|"noise")`
  - 3 adult: still ≥ 1.0 after 60 s of calm → status tier 3 (app alerts adults)
  - back down when < 0.4 for 10 s.
- **After calm ends**: a 10-second check-in screen with three big faces
  (better / same / worse); the answer goes on the end report as `child_feeling`.
- **Scene**: use `scene_pick` from the latest poll if it is in this week's set,
  otherwise the existing rotation.
- **GPS** (S3 Plus, TinyGPSPlus on GPSSerial): only when `settings.gps_enabled`.
  Trail point every 5 min; calm-start report carries the latest fix (≤ 10 min old).

## device-api changes

`GET /poll` response adds:
```json
{ "settings": { "auto_motion": true, "auto_noise": false, "motion_k": 2.5, "noise_k": 2.5, "gps_enabled": false },
  "scene_pick": "ocean_rain" }
```
(`scene_pick` from `private.pick_scene(child_id)`; may be null.)

`POST /status` body adds (all optional):
```json
{ "agitation": 0.42, "tier": 1,
  "samples": [ { "at": "ISO", "motion": 0.1, "noise_db": 58.2, "motion_z": 0.4, "noise_z": 1.1, "agitation": 0.42 } ] }
```
→ `devices.agitation/agitation_at/tier`; samples (≤ 60, at within ±10 min of
now) → `sensor_samples`.

`POST /events` items add (all optional): `agitation_peak`, `tier`,
`child_feeling` ("better"|"same"|"worse"), `lat`, `lng`, `accuracy_m`.
When an item has `ended_at`: call `private.compute_event_outcome(event_id)`.
When it has lat/lng and `child_settings.gps_enabled`: insert `locations` kind
`calm` with the event_id.

`POST /location` (new): `{ "points": [ { "at", "lat", "lng", "accuracy_m" } ] }`
(≤ 20) → `locations` kind `trail`, only if `gps_enabled` (else 204, dropped).

## insights edge function (new, verify_jwt on)

`POST /functions/v1/insights { "child_id": "…" }` with the user's JWT.
Checks access with the user's client (RLS), gathers `child_pattern_stats(28)`,
`scene_stats`, `risk_forecast(24)`, last 7 days of events (trigger, local time,
scene, helped, false_alarm, child_feeling, agitation before/after, recovery) and
journal entry bodies (nickname replaced by "the child"; no names sent). Gemini
structured output →
```json
{ "headline": "…", "patterns": ["…"], "what_helps": ["…"], "suggestions": ["…"],
  "risk_windows": [ { "day": "Tue", "from": "10:00", "to": "11:00", "why": "…" } ] }
```
Upsert into `weekly_insights` (service role), return the row.

## App / website read

- `child_settings` (parent updates auto_motion, auto_noise, gps_enabled, gps_consent_at)
- `sensor_samples` (realtime), `devices.agitation/tier` (realtime)
- `sensitivity_log`, `events.false_alarm` (teacher updates), outcome columns
- RPCs: `scene_stats(child)`, `child_pattern_stats(child, days)`, `risk_forecast(child, hours)`
- `weekly_insights`, `locations` (parent always; teacher only in school hours)
