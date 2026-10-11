# Ebb

**A calm corner on the wrist.** Ebb is a calming smartwatch for K-12 students with special
needs. It notices rising stress early, helps the child calm down, learns what works for
that child, and keeps parents and teachers in the loop.

Ebb is a support tool that works alongside teachers, parents and therapists. It is not a
medical device and does not diagnose or treat anything.

- Website: https://useebb.tech
- Hardware: LilyGO T-Watch S3 Plus (ESP32-S3)
- Built at HackNC 2026

## What it does

**On the watch**
- Senses agitation from repetitive movement (rocking, hand-flapping) and room loudness,
  compared with the child's own learned normal. Loudness levels only; no audio is recorded.
- Responds in steps: a gentle breathing buzz → calm mode starts on its own → a "needs an
  adult" alert if the child is still agitated after a minute.
- Calm mode: a full-screen nature scene (real footage), a breathing circle, soft sound,
  vibration and short phrases in a calm voice (an AI voice, or the parent's own voice).
- The child can end calm with "I'm OK", or tap a face afterwards (better / same / worse).
- Calm can also start from the child's tap or a teacher/parent in the app or on the website.

**It learns**
- Measures every calm moment: agitation before and after, and how long it took to settle.
- Teacher ratings ("Helped" / "Didn't help" / "False alarm") tune the sensitivity per child.
- Thompson sampling picks the scene most likely to help at each time of day, using the
  teacher's rating, the child's check-in and the measured drop as the reward.
- An empirical-Bayes forecast of the riskiest hours, and an AI weekly report.

**For the adults**
- iPhone app: QR pairing, assessment → AI calm profile → parent approval, voice choice,
  weekly scenes, live agitation graph, calm moments with outcomes, teacher journal notes,
  insights, optional location, phone sign-in.
- Website (Lovable): teacher and parent portals, class board, insights.
- iMessage (Photon): text Ebb "How was Sam today?"; notes are shared between home and school.

## Architecture

```
             ┌──────────── iPhone app (SwiftUI) ───────────┐
             │  login · pairing · live graph · insights     │
             └──────────────┬───────────────────────────────┘
Website (Lovable) ──────────┤  Supabase Auth + Postgres (row-level security on every table)
                            │  Realtime: events, devices, sensor_samples, journal
Watch (ESP32-S3) ── HTTPS ──┤  Edge Functions:
  poll every 3 s            │    device-api      the only API the watch talks to
  status + samples ~5 s     │    generate-profile assessment → Gemini → calm profile
  events, location          │    insights        weekly report (Gemini)
                            │    voice           ElevenLabs voice + phrase clips
                            │    sms-hook        Supabase "Send SMS" hook → text outbox
                            │    messaging       iMessage questions/notes (Gemini)
Photon bridge (Mac) ────────┘  ←→ Photon iMessage line
```

Secrets (Gemini, ElevenLabs, Photon, bridge secret) live only in Supabase function secrets
or the local `photon-bridge/.env`; never in the app, the website, the watch or this repo.

## Repo map: how each part was built

### `firmware/ebb/` — the watch (Arduino C++, ESP32 core 2.0.9, LVGL 8.4, LilyGoLib)
Two FreeRTOS tasks: the UI/sensor loop on core 1, all HTTP on a network task on core 0.

| File | What it does / how |
|---|---|
| `ebb.ino` | Setup and main loop; home screen (time, battery, agitation ring around Start calm); serial debug keys (`s`, `x`, `v`, `u`, `a`, `g`) |
| `config.h` | Tunable numbers (poll interval, calm length, sample rate, firmware version) |
| `secrets.example.h` | Template for Wi-Fi and server settings (`secrets.h` is gitignored) |
| `net.cpp/.h` | Wi-Fi, HTTPS with pinned root certificates, SNTP clock (timestamps only trusted after a real sync), download helper |
| `pairing.cpp/.h` | Shows a QR code until a parent claims the watch; stores the device token in NVS |
| `commands.cpp/.h` | Network task: polls `device-api/poll`, runs start/stop, receives the calm profile, settings and the server's scene pick, then flushes status and location |
| `calm_mode.cpp/.h` | Calm screen: scene GIF, breathing circle animation, haptics, sound and voice, "I'm OK" button, 3-minute limit |
| `checkin.cpp/.h` | 10-second "How do you feel?" screen with three drawn faces |
| `motion.cpp/.h` | BMA423 accelerometer at 25 Hz: high-pass magnitude, 128-sample window, energy × autocorrelation periodicity (0.5–3 Hz) → repetitive-motion score |
| `noise.cpp/.h` | PDM microphone on its own task: RMS of 100 ms frames → dB (levels only, never audio) |
| `agitation.cpp/.h` | Per-child EWMA baselines (saved to NVS), z-scores, agitation level, tier state machine with hysteresis and dwell times, breathing cue, auto-start, cooldown, session peak |
| `telemetry.cpp/.h` | Buffers samples and posts `/status` (agitation, tier, battery, samples) |
| `event_log.cpp/.h` | Start/end reports for each calm session (trigger, scene, peak, tier, child's feeling, GPS fix); queued while offline |
| `settings.cpp/.h` | Auto-start switches and learned sensitivity from the server, kept in NVS |
| `profile_store.cpp/.h` | The approved calm profile, kept in flash so calm works offline |
| `scenes.cpp/.h` | This week's 6 approved scenes; rotation and lookup |
| `media.cpp/.h` | Downloads scene videos and sounds to FFat |
| `voice.cpp/.h` | Downloads approved voice clips; picks one to play every few breaths |
| `audio_player.cpp/.h`, `loud_output.h` | MP3 → I2S speaker via ESP8266Audio, with a high-pass filter and soft limiter for loudness |
| `gps.cpp/.h` | Optional GPS (TinyGPSPlus): trail points every 5 min, only when the parent opted in |
| `ca_certs.h` | Root certificates for HTTPS |
| `ui.cpp/.h`, `sounds.h` | Placeholders from the original plan |

`firmware/tools/mock_device_api.py` — a local fake of device-api for testing without Supabase.

### `app/` — iPhone app (SwiftUI, iOS 17, supabase-swift, XcodeGen)

| File | What it does |
|---|---|
| `Ebb/Theme.swift` | Design system from our mockups (cream cards, green title bars, teal buttons, chips) |
| `Ebb/AppModel.swift` | All data access: auth (email and phone OTP), realtime, commands, profiles, voice, scenes, ratings, journal, insights, location |
| `Ebb/Models.swift` | Codable types for every table and RPC |
| `Ebb/EbbApp.swift`, `Ebb/DesktopView.swift` | App entry, "ebb Desktop" welcome screen with Launchpad info pages |
| `Ebb/LoginView.swift` | Email or phone sign-in, create account |
| `Ebb/HomeView.swift` | Children / class list, child cards (status, battery, Start/Stop), latest moment, rating, journal notes, account menu (add phone) |
| `Ebb/PairView.swift`, `Ebb/QRScannerView.swift` | Scan the watch QR, choose or add a child (with consent), teacher join |
| `Ebb/AssessmentView.swift`, `Ebb/CalmProfileView.swift` | Calm assessment → AI calm profile preview → approve |
| `Ebb/VoiceView.swift` | AI voice or own-voice recording (consent), phrases, listen and approve clips |
| `Ebb/ScenesView.swift` | This week's scenes, swap, approve |
| `Ebb/LiveView.swift` | Live agitation chart, auto-start switches, "What Ebb learned" |
| `Ebb/InsightsView.swift` | Heatmap, scene effectiveness bands, risk forecast, AI weekly report |
| `Ebb/LocationView.swift` | Opt-in GPS map (trail and calm pins), consent |
| `project.yml` | XcodeGen project definition |

### `supabase/` — backend
- `migrations/0001…0026` — the whole schema, in order: tables, row-level security, column
  grants and security-definer functions for pairing, journal, voice, scene sets,
  teacher-only ratings, adaptive sensing (settings, samples, self-tuning sensitivity),
  scene bandit, pattern stats, risk forecast, weekly insights, locations with school-hours
  access, retention jobs (pg_cron), Photon text outbox and security fixes.
  `0018d_retention_run_manually.sql` was run by hand in the SQL editor.
- `functions/device-api/` — the watch API (device-token auth): poll, events, status,
  location, voice, scenes, pairing. `adaptive.ts` mirrors the SQL Thompson sampling and
  outcome math.
- `functions/generate-profile/` — assessment answers → Gemini structured output → validated
  calm profile draft.
- `functions/insights/` — weekly AI report from stats, scene results, forecast, events and
  journal (names removed before sending).
- `functions/voice/` — ElevenLabs voice cloning (with consent) and phrase clips.
- `functions/sms-hook/` — Supabase Auth "Send SMS" hook (Standard Webhooks signature) →
  queues login codes.
- `functions/messaging/` — iMessage: answers questions, saves notes, relays journal posts;
  outbox for the bridge.
- `functions/demo-narration/` — retired (returns 410); made the demo video's voiceover.
- `tests/children_rls.test.sql` — row-level security test.

### `photon-bridge/` — iMessage bridge (Node, spectrum-ts)
Runs on a Mac during the demo: forwards incoming iMessages to `messaging/inbound`, sends the
replies, and delivers queued login codes and relays. Setup in `docs/photon-setup.md`.

### `web/` — first website prototype (Next.js)
Our initial teacher/parent site. The live site at useebb.tech was rebuilt in Lovable on the
same Supabase project; the prompts we gave Lovable are in `docs/lovable-*.md`.

### `media/tools/` — scene media
`make_media.sh` turns free-licensed footage and sounds (see `docs/credits.md`) into the
watch's GIFs and MP3s; `make_generated.py` made early placeholder scenes.

### `docs/`
Architecture, privacy, assessment questions, app UI guide, the adaptive-features contract,
Photon setup, Lovable prompts, demo script, and the demo video renderer
(`demo-video/render.py`).

## How we used AI

### AI inside the product
| Where | Model / API | What it does | Safeguards |
|---|---|---|---|
| Calm profiles (`generate-profile`) | Google Gemini `gemini-3.5-flash-lite` | Turns the parent's assessment into a calm profile (theme, colours, breathing, vibration, sound, message) | Structured JSON output; server-side validation so it can only pick options the watch can play; child's name never sent; parent must approve |
| Weekly report (`insights`) | Google Gemini | Patterns, what helps, suggestions, risky time windows | Child and adult names removed before sending; numbers come from SQL, not the model |
| Texting (`messaging`) | Google Gemini | Sorts a text into question / note / calm request; answers questions from that child's data only | Child's name masked; only confirmed, linked phone numbers; calm can't be started by text; rate limit |
| Calm voice (`voice`) | ElevenLabs `eleven_v4` (fallback `eleven_multilingual_v2`) | Speaks calming phrases; optional clone of the parent's voice | Explicit consent; recording not kept; cloned voice deletable |

Not generative AI: the on-watch agitation detection (per-child baselines, z-scores,
autocorrelation) and the learning (Thompson sampling, empirical-Bayes forecast,
sensitivity tuning) are classical statistics written by hand.

### AI as a development tool: who built what

We were open about using AI assistants. Here is the honest split.

**Written by Claude (Anthropic's Claude Code, as our coding assistant)**, directed, reviewed
and tested by us on the real watch, phone and backend:
- **All watch firmware** in `firmware/ebb/`: networking, pairing, calm mode, the motion and
  noise signal processing, the agitation tiers and auto-start, telemetry, check-in, GPS,
  the home screen. Also the bug fixes found on hardware (HTTPS clock, audio gain overflow,
  the 7-hour RTC clock offset, motion sensitivity).
- **The whole iPhone app** in `app/`, implemented from our team's UI mockups.
- **The whole Supabase backend**: every migration in `supabase/migrations/` (schema,
  row-level security, SQL functions, Thompson sampling, forecast, retention jobs) and every
  Edge Function in `supabase/functions/`.
- **The Photon iMessage bridge** (`photon-bridge/`), the AI prompts sent to Gemini, the
  media pipeline scripts, the first Next.js prototype (`web/`), the demo video renderer
  (`docs/demo-video/`), and the docs, including the prompts we pasted into Lovable.
- **Security reviews**: automated reviews flagged issues that Claude then fixed
  (migrations 0016, 0021, 0022, 0024, 0025; messaging and bridge hardening).

**Made by our team:**
- The idea, the problem framing, and every product decision (what the watch does, tiers,
  privacy rules, teacher-only ratings, school-hours location, what texting may do).
- **App UI design**: the 21 screen mockups (Frutiger-Aero / XP-inspired look) that the
  app was built to match.
- **The website** at useebb.tech, built by a teammate in **Lovable** (AI website builder)
  on our Supabase backend, and the domain and DNS setup.
- **Hardware bring-up and testing**: flashing and testing the watch, Wi-Fi and hotspot
  setup, tuning on the wrist, end-to-end tests of pairing, alerts, texting and auto-start.
- **Accounts and secrets**: Supabase project, Gemini and ElevenLabs keys, Photon project,
  auth hook, all set up by us; no secret was ever given to the AI.
- Choosing the calm scenes and sounds, the voice, the demo and the pitch.

**Other AI services used during the build:** Lovable (website generation) and ElevenLabs
(the demo video's voiceover, same voice as the watch).

## Backend infrastructure we built

All on one **Supabase** project (Postgres 17), plus three external APIs and a small bridge.

| Layer | What we set up |
|---|---|
| **Database tables** (public, all with row-level security) | `profiles`, `children`, `child_members` (teacher links), `devices`, `pairing_sessions`, `commands`, `events`, `assessments`, `calm_profiles`, `scenes`, `scene_sets`, `scene_set_items`, `parent_voices`, `voice_clips`, `journal_entries`, `journal_comments`, `child_settings`, `sensor_samples`, `sensitivity_log`, `weekly_insights`, `locations` |
| **View** | `child_day_summary` (per-day counts for dashboards) |
| **Private tables** (no client access) | `pairing_attempts` (rate limit), `outbound_texts` (text outbox), `text_threads`, `processed_texts` |
| **SQL functions (RPC)** | pairing (`pair_claim_watch`, `pair_join_watch`, `claim_watch`, `join_watch`, `add_teacher_by_email`), `make_scene_set`, `scene_stats`, `child_pattern_stats`, `risk_forecast`, texting (`ebb_text_*`, service role only) |
| **Triggers** | rating log stamp, sensitivity self-tuning, child settings on new child, GPS-off erase, journal → text relay, text outbox → send |
| **Auth** | Email + password, phone sign-in by one-time code; custom **Send SMS hook** (Edge Function) delivers codes over iMessage instead of Twilio |
| **Realtime** | `events`, `devices`, `sensor_samples`, `journal_entries`, `journal_comments` |
| **Storage** | `scene-media` (public: scene videos and sounds for the watch), `voice-clips` (private: signed URLs only) |
| **Edge Functions (Deno)** | `device-api`, `generate-profile`, `insights`, `voice`, `sms-hook`, `messaging` (`demo-narration` retired) |
| **Scheduled jobs** (`pg_cron`, `pg_net`) | `ebb-retention` hourly (sensor samples after 2 days, locations after 30 days); `ebb-text-drain` every minute (retry queued texts) |
| **Secrets** | Function secrets (Gemini, ElevenLabs, bridge, SMS hook) and a database-generated **Vault** secret for the text drain |
| **External APIs** | Google Gemini, ElevenLabs, Photon (iMessage) |
| **Bridge** | `photon-bridge/`: Node process holding Photon's persistent connection |
| **Website hosting** | Lovable, on the custom domain useebb.tech |

## Running it

- **Watch:** Arduino IDE with ESP32 core 2.0.9, LilyGoLib, LVGL, ESP8266Audio, ArduinoJson,
  TinyGPSPlus. Board settings in `firmware/README.md`. Copy `secrets.example.h` to
  `secrets.h`. Needs 2.4 GHz Wi-Fi.
- **Backend:** apply `supabase/migrations` in order; deploy the functions; set
  `GEMINI_API_KEY`, `ELEVENLABS_API_KEY`, `BRIDGE_SECRET`, `SEND_SMS_HOOK_SECRET` as
  function secrets (see `supabase/functions/.env.example`).
- **App:** `cd app && xcodegen generate`, open `Ebb.xcodeproj`, set your team, run.
- **Texting:** see `docs/photon-setup.md`.

## Privacy

Nickname and age band only; no audio; row-level security on every table; AI never receives
names; location is opt-in (teachers only on school days 8am–3pm; deleted after 30 days);
live sensor readings deleted after 2 days. Details in `docs/privacy.md`.

## License

See `LICENSE`. Media credits in `docs/credits.md`.
