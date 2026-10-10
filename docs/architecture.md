# Architecture

The teacher's button writes a command to the database; the watch picks it up on its next 3-second poll and posts an event back, which shows up live for the teacher and parent. The AI key sits in `generate-profile` and never reaches the website or the watch.

```
Teacher / parent browser (Next.js on Vercel)
   │  Supabase Auth + Postgres under RLS
   │  insert into commands            Realtime: new events / device status
   ▼                                   ▲
Supabase ── Edge Function device-api ◀─┼── watch: GET /poll every 3 s, POST /events, POST /status
   │                                   │
   └── Edge Function generate-profile ─┴── Claude API (structured outputs) → draft calm profile
```

## Watch (firmware/)
Arduino C++ on the LilyGO T-Watch S3 Plus. One loop polls for teacher commands every 3 seconds on a background task, watches motion and noise in between, and runs calm mode. Each job is its own module. If WiFi drops, motion, noise and the child's tap still work, and events upload on reconnect.

## device-api (supabase/functions/device-api)
The only server code the watch talks to. Every call carries `Authorization: Bearer <device token>`; the function hashes it and looks it up in `devices.token_hash`. `poll` returns pending commands and marks them delivered, `events` saves calm sessions, `status` saves battery and calm state.

## Website (web/)
Teachers see their students with a big Start calm button each. Parents set up their child, take the assessment, approve the AI-made calm profile and see a history. Start calm is a plain insert into `commands` under RLS.

## Database (supabase/migrations)
Eight tables, all with Row Level Security, so a teacher or parent can only reach students they are linked to. Realtime is on for `events` and `devices`.

## AI (supabase/functions/generate-profile)
Turns the parent's assessment answers into a small JSON profile that only uses options the watch can actually play. Saved as a draft; the parent approves it before the watch downloads it.
