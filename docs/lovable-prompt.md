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
  noise_db, motion_score, helped (true/false/null)
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
   - Today: timeline of today's tantrums (time, trigger, duration, helped). Each tantrum has
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
   - Today: tantrum timeline with the teacher's note under each, and an "Ask a question" box
     on every note (writes journal_comments).
   - Journal: all day notes and tantrum notes, newest first, each with its thread.
   - History: same 14-day chart and day list as the teacher view; "Did it help?" totals.
   - Calm profile: the approved profile shown as friendly chips (theme, sound, breathing pace,
     vibration) plus calm_message and parent_summary. Read-only here; it is set in the iPhone app.
   Parents cannot write journal entries, only questions.

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
- Do not create or alter tables, policies or functions, or use a service-role key.
- Do not show GPS or location yet (coming later as its own feature).
````
