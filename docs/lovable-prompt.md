# Prompt for the Ebb website (Lovable)

Paste everything inside the box below into Lovable. Send the demo password
separately (it is not in git); ask Vineet for it.

````text
Build the Ebb website: a calm, friendly dashboard for parents and teachers of
children who use the Ebb calming watch. It only READS data and handles the
teacher journal. It does NOT start or stop calm mode (that is the iPhone app).

## Backend (already exists, do not create tables or migrations)
Use the existing Supabase project. Do not enable Lovable Cloud or create a new database.
- URL: https://pchbznvjjmfcfjwrbmvj.supabase.co
- Publishable key: sb_publishable_qVnoz13SGD8kSMGXfyr-_A_z2iZPBB9
- Never use or ask for a service-role / secret key in the website.
Row Level Security already limits every query to the signed-in user's own or
linked children, so the website never filters for security itself.

## Login
- Email + password with Supabase Auth.
- Sign up: supabase.auth.signUp({ email, password, options: { data: { role: 'parent' | 'teacher', display_name } } }).
  A trigger creates the profiles row.
- After login read profiles.role and route parents to /parent, teachers to /teacher.
- Demo accounts: parent.demo@ebb.test and teacher.demo@ebb.test (password shared separately).
  The demo student is "Sam".

## Tables and views to read (public schema)
- profiles: id, display_name, role ('parent' | 'teacher')
- children: id, owner_id (the parent), nickname, age_band ('4-5','6-8','9-11','12-14','15-18'), consent_at
- child_members: child_id, user_id (a linked teacher)
- devices: id, child_id, last_seen_at, battery_pct, calm_active, firmware_version
  (a watch is "online" if last_seen_at is within 30 seconds)
- events = one calm session ("tantrum"): id, child_id, trigger ('teacher' | 'child_tap' | 'motion' | 'noise'),
  started_by (profile id when a teacher started it), started_at, ended_at (null while still calming),
  noise_db, motion_score, scene_id (which calm scene played, see scenes),
  helped (true/false/null = the teacher's "Did it help?"), helped_by (profile id of the teacher who rated),
  helped_at (when it was rated). Only linked teachers can set helped; helped_by/helped_at are stamped
  automatically by the database.
- scenes: id, title (e.g. "Earth and rain"), video, sound. Join events.scene_id -> scenes.title.
  Preview GIF: https://pchbznvjjmfcfjwrbmvj.supabase.co/storage/v1/object/public/scene-media/<video>.gif
- scene_sets (child_id, week_start, status 'draft'|'approved') + scene_set_items (set_id, position 1-6,
  scene_id, is_anchor): the 6 scenes the watch rotates through each week (managed in the iPhone app).
- child_day_summary (view): child_id, day (date, US Eastern), sessions, calm_minutes, by_teacher,
  by_child_tap, by_motion, by_noise, helped_yes, helped_no, active_now, first_started_at, last_started_at
- calm_profiles: child_id, version, status ('draft' | 'approved'), profile (jsonb: theme, colors,
  breath_pattern, vibration, sound, volume, calm_message, parent_summary)

## Teacher journal (the website writes these)
- journal_entries: id, child_id, kind ('event' | 'day'), event_id (when kind='event'), day (date, when kind='day'),
  author_id, body, created_at, updated_at
  - Teachers only. One entry per teacher per tantrum, and one per teacher per child per day.
  - Insert: { child_id, kind: 'event', event_id, body } or { child_id, kind: 'day', day: 'YYYY-MM-DD', body }.
  - Only the author can edit (update body) or delete.
- journal_comments: id, entry_id, author_id, body, created_at
  - Parents ask questions here; teachers answer. Both insert { entry_id, body }.
- Show each author's display_name and role from profiles (join on author_id).

## Live updates
Subscribe with Supabase Realtime (postgres_changes) to inserts/updates on events, devices,
journal_entries and journal_comments, and refresh the open page. Show a soft banner
"<nickname> started calm mode" when a new event arrives with ended_at null.

## Labels
trigger: teacher -> "Started by teacher", child_tap -> "<nickname> asked for calm", motion -> "Movement detected",
noise -> "Loud room". Duration = ended_at - started_at in minutes; "Calming now" if ended_at is null.
Times in the browser's local time; days follow child_day_summary.day.

## Teacher portal (/teacher)
1. Class page: a card per linked child: nickname, watch status (online / offline / "Calming now"),
   today's sessions and minutes, a dot timeline of today's tantrums by hour.
2. Child page (/teacher/child/:id), three tabs:
   - Today: timeline of today's tantrums (time, scene title, trigger, duration, and the rating:
     "Helped" / "Didn't help" / "Not rated", with "rated by <teacher name> at <time>" from
     helped_by + helped_at). Teachers can rate unrated ones here too (update events.helped). Each tantrum has
     "Write note" / "Edit note" opening its journal entry, and shows the parent's questions
     under it with a reply box.
   - Day journal: one note per day (date picker, defaults to today), with its question thread.
   - History: last 14 days from child_day_summary as a bar chart (sessions per day, stacked by
     trigger) and a list of past days; clicking a day shows that day's tantrums and notes.
3. A "Questions from parents" inbox listing comments from parents that have no teacher reply after them.

## Parent portal (/parent)
1. Overview: a card per child with today's summary ("3 calm moments, 7 minutes"), watch
   status and battery, and the latest teacher note.
2. Child page (/parent/child/:id):
   - Today: tantrum timeline (time, scene, duration, the teacher's rating with who/when) with the teacher's note under each, and an "Ask a question" box
     on every note (writes journal_comments).
   - Journal: all day notes and tantrum notes, newest first, each with its thread.
   - History: same 14-day chart and day list as the teacher view; "Did it help?" totals, and a small
     "What helps" list: scenes ranked by how often the teacher rated them helped.
   - Calm profile: the approved profile shown as friendly chips (theme, sound, breathing pace,
     vibration) plus calm_message and parent_summary. Read-only here; it is set in the iPhone app.
   Parents cannot write journal entries, only questions.

## Adaptive Ebb (new: the watch senses rising agitation and learns per child)
All of this already exists in the database. Do NOT create or alter tables, columns, policies,
views or functions, and do not write SQL migrations. Only read these, call these RPCs, and do
the few updates listed.

New tables and columns (public schema):
- child_settings (one row per child): child_id, auto_motion, auto_noise (watch may start calm by
  itself), motion_k, noise_k (sensitivity, learned; lower = calm starts sooner; read-only),
  gps_enabled, gps_consent_at, updated_at.
  Parents may update only auto_motion, auto_noise, gps_enabled, gps_consent_at.
  gps_enabled = true requires gps_consent_at in the SAME update
  (e.g. { gps_enabled: true, gps_consent_at: new Date().toISOString() }), else the update fails.
- devices adds: agitation (0..1+, 1 = the auto-start line), agitation_at, tier
  (0 settled, 1 rising = breathing cue on the wrist, 2 calm mode, 3 needs an adult).
- sensor_samples: id, child_id, device_id, at, motion (0..1), noise_db, motion_z, noise_z, agitation.
  One row per watch reading (about every 5 s); only the last 2 days are kept.
- events adds: false_alarm (teachers set true/false on motion/noise starts), agitation_peak,
  tier (highest tier reached, 1-3), child_feeling ('better' | 'same' | 'worse', the child's
  check-in on the watch), agitation_before, agitation_after (mean over 60 s before start /
  after end), recovery_seconds (start -> back under 0.5).
- sensitivity_log: id, child_id, event_id, at, signal ('motion' | 'noise'), old_k, new_k,
  reason ('false alarm' | 'helped'). Written by the database when teachers rate.
- weekly_insights: id, child_id, week_start (Monday), stats (jsonb), report (jsonb:
  headline, patterns[], what_helps[], suggestions[], risk_windows[{ day, from, to, why }]),
  model, created_by, created_at. Written only by the insights function (read it, never insert).
- locations: id, child_id, device_id, event_id, at, lat, lng, accuracy_m, kind ('trail' | 'calm').
  RLS: the parent always sees their child's points; a linked teacher sees only points recorded
  in school hours (Mon-Fri 08:00-15:00 New York) and only while it is school hours now.

RPCs (supabase.rpc; each checks access itself and returns nothing for other children):
- scene_stats({ p_child_id }) -> rows { scene_id, title, bucket ('all' | 'morning' | 'afternoon'
  | 'evening'), helped, not_helped, mean, low, high } (mean = chance it helps, low/high = 90% band)
- child_pattern_stats({ p_child_id, p_days: 28 }) -> jsonb { days, total, heatmap: [{ dow 1=Mon..7,
  hour 0-23, count }], by_trigger: { <trigger>: { count, helped, not_helped, false_alarms } },
  avg_minutes, avg_agitation_peak, busiest: { dow, hour, count } } (hours are New York time)
- risk_forecast({ p_child_id, p_hours: 8 }) -> rows { hour_start, expected, risk (0..1), level
  ('low' | 'medium' | 'high') } for each coming hour
- Edge function: supabase.functions.invoke('insights', { body: { child_id } }) -> the new
  weekly_insights row (it replaces this week's row). Takes ~5-20 s. Errors come back as
  { error: "..." }; 502 means the AI failed (show "Couldn't write the report, try again"),
  503 means AI not set up.

Features to build:
1. Live agitation board (teacher class page and parent overview): per student a soft gauge or
   bar of devices.agitation with the tier as words ("Settled", "Rising, breathing cue on",
   "Calming", "Needs an adult"), plus a 10-minute sparkline from sensor_samples (latest first,
   at >= now - 10 min). Subscribe with Realtime to UPDATE on devices and INSERT on
   sensor_samples (filter child_id=eq.<id>) and update live. Tier 3 shows a gentle but clear
   banner "<nickname> may need an adult". Treat agitation older than 60 s as "no recent reading".
2. Insights page (/teacher/child/:id/insights and /parent/child/:id/insights):
   - Heatmap: weekday (Mon-Fri, plus weekend if any data) x hour (7-18) from
     child_pattern_stats.heatmap, with a text summary of the busiest time.
   - Scene effectiveness: horizontal bars of mean per scene (bucket 'all' by default, a
     morning/afternoon/evening switch), with the low-high 90% band drawn as a whisker and
     "n ratings" = helped + not_helped. Grey out scenes with 0 ratings ("not tried yet").
   - Risk forecast: the next 8 hours as a row of chips coloured by level, with time labels.
   - AI report: the newest weekly_insights row (headline, patterns, what helps, suggestions,
     risk windows) with "Written <date> by AI. Check it against what you see." and a
     "Generate insights" button that calls the insights function, shows a spinner, then
     renders the returned row.
   - Outcomes: for recent calm moments show before -> after agitation, recovery time and the
     child's check-in face (better / same / worse).
3. Sensitivity learning log (on the insights page): list from sensitivity_log, e.g.
   "Movement sensitivity 2.5 -> 2.8 after a false alarm (Tue 10:14)", plus the current
   motion_k / noise_k from child_settings explained as "lower = calm starts sooner".
   Teachers get a "False alarm" toggle next to each motion/noise calm moment (update
   events.false_alarm), beside the existing "Did it help?" rating.
4. Parent settings (/parent/child/:id/settings): switches for "Start calm automatically when
   movement rises" (auto_motion) and "... when the room gets loud" (auto_noise).
5. GPS map, parents (/parent/child/:id/map): a consent card explaining that the watch will
   record its location every 5 minutes and at each calm moment, kept for 30 days, visible to
   the parent and to linked teachers in school hours only. Toggle on = update { gps_enabled:
   true, gps_consent_at: now }; toggle off = { gps_enabled: false } (the watch stops sending).
   The map (Leaflet + OpenStreetMap tiles) shows the trail (kind 'trail', a line for the
   chosen day) and calm pins (kind 'calm', linking to the calm moment). Default to today.
6. GPS map, teachers: same map read-only, no toggle; only show the tab during school hours
   (Mon-Fri 08:00-15:00 America/New_York) and explain "Location is only shown in school hours".
   Outside those hours RLS returns no rows anyway.

## Look and feel
- Calm and soft: off-white background (#F7F9F8), deep teal primary (#1F7A7A), sky accent (#7FB7D6),
  warm sand for highlights (#F2E3C6), muted red only for errors. Plenty of white space.
- Rounded cards (16px radius), soft shadows, one clear action per card.
- Friendly sans-serif (e.g. Nunito or Inter), large readable text; never alarming language
  ("calm moment", not "incident").
- Mobile-first: parents mostly use phones. Sidebar on desktop, bottom tabs on mobile.
- Empty states that explain what will appear ("No calm moments today").
- Accessible: 4.5:1 contrast, every control reachable by keyboard, charts with text summaries.

## Do not
- Do not add Start calm / Stop buttons (iPhone app only).
- Do not create or alter tables, columns, policies, views or functions, write migrations,
  or use a service-role key. Everything above already exists.
- Do not insert into weekly_insights, sensor_samples, sensitivity_log or locations (the
  backend writes them), and do not update motion_k / noise_k.
- Do not show location to teachers outside school hours, and never show the map to a parent
  before they have given consent.
````
