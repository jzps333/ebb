Add a "Class board" page to the teacher portal (route /teacher/board, and a "Class board"
button at the top of the teacher home). It shows every student the signed-in teacher is
linked to as a live tile, coloured by how agitated they are right now. Use the existing
Supabase client and tables. Do NOT create or change any tables, policies or migrations.

DATA (all already exist; row-level security limits rows to the teacher's own students)
- public.children: id, nickname, age_band
- public.devices: child_id, last_seen_at, battery_pct, calm_active, agitation (0..~3),
  agitation_at, tier (0 settled, 1 rising, 2 calm mode, 3 needs an adult)
  A child may have no device row (no watch yet). If there are several, use the one with the
  newest last_seen_at.
- public.child_settings: child_id, auto_motion, auto_noise
- public.sensor_samples: child_id, at, agitation (for a small sparkline: last 10 minutes)
- public.child_day_summary: child_id, day (YYYY-MM-DD, America/New_York), sessions
- Realtime is enabled on public.devices and public.sensor_samples: subscribe to UPDATE on
  devices and INSERT on sensor_samples and update tiles live, without reloading.
- Start/stop calm: insert into public.commands { device_id, child_id, type:
  "start_calm" | "stop_calm", created_by: auth user id } (same as the existing Start button).

TILE (responsive grid: 4 columns desktop, 2 tablet, 1 phone)
- Big nickname, age band ("Age 6–8"), and today's calm moments count.
- Colour band + status chip from the device:
  - offline (last_seen_at older than 60 s, or no watch): grey, "Watch offline" / "No watch"
  - tier 0 and agitation < 0.6: green, "Settled"
  - tier 1, or agitation 0.6–1.0: amber, "Rising"
  - tier 2 or calm_active: teal, "Calm mode"
  - tier 3: red, pulsing border, "Needs an adult", and move the tile to the top
- A thin horizontal agitation bar (0 to 1.5, full = 1.5) with a dashed marker at 1.0
  labelled "auto-start", and a sparkline of the last 10 minutes of sensor_samples.agitation.
- Small icons: battery % (red at 20% or below), "Auto: movement / loud room" if enabled.
- Buttons: "Start calm" (primary) and "Stop" (secondary), disabled when there is no
  watch; show "Sending…" while the insert is in flight.
- Clicking the tile (not the buttons) opens that student's existing detail page.

PAGE
- Header: "Class board", the teacher's name, and a live dot "Live" when realtime is
  connected ("Reconnecting…" otherwise).
- Summary strip above the grid: counts of Needs an adult / Calm mode / Rising / Settled /
  Offline, each a small coloured pill.
- When any tile becomes "Needs an adult", show a red banner at the top:
  "<nickname> needs an adult" with a "View" link, and play no sound.
- Empty state: "No students yet. Scan a student's watch in the Ebb app while the parent
  is pairing it."
- Never show made-up data. If a value is missing, show "—".

LOOK
Same Ebb style as the rest of the site: cream background (#EFF2E5), cream cards (#FAFAF2,
border #C9CFB9, radius 16) with the green gradient title bar (#F0F6DD → #ABBF8D),
teal buttons (#21657A), ink text (#2B3A2C). Colours for states: green #66B45C,
amber #E8B03C, teal #21657A, red #D65C48, grey #B8BDB0. Large, calm, easy to read
from across a classroom.
