Fill in every category of the Ebb website with the exact content below. Keep the current
design (the "ebb Desktop" look: cream cards with green title bars, glossy teal buttons,
the Launchpad tiles). Use this copy as written; tighten wording only if a card overflows.
Do NOT create or change any database tables, policies or migrations. Every "Open ebb" /
"Sign in" button goes to the existing login, then the teacher or parent portal.

=====================================================================
1. ebb Home
=====================================================================
Headline: "A quieter way to stay connected."
Subhead: "Ebb is a calming smartwatch for kids with special needs. It notices rising stress
early, helps the child calm down, and keeps parents and teachers in the loop."
Primary button: "Open ebb" → login. Secondary: "How it works" → section 3.

Three highlight cards:
- "Notices first" — Learns each child's own normal from movement (rocking, hand-flapping)
  and room loudness. Loudness levels only, never audio.
- "Calms in steps" — A gentle breathing buzz, then a calm scene with a familiar voice,
  then an alert to the nearest adult if it's still needed.
- "Learns what works" — Measures how much each calm moment helped and adapts to the child.

Stat strip (label these as "How Ebb works", not as results):
"3 response steps" · "6 calm scenes a week, chosen per child" · "0 audio recorded"

=====================================================================
2. The Watch
=====================================================================
Title: "A calm corner on the wrist"
Intro: "Ebb runs on a LilyGO T-Watch S3 Plus: touch screen, vibration motor, speaker,
motion sensor, microphone (for loudness only), Wi-Fi and optional GPS."

Section "What the child sees":
- A full-screen calm scene from real nature footage (ocean, rain, forest, space, gentle
  shapes, animals), a breathing circle that grows and shrinks, and a short calming message.
- Soft sounds (rain, ocean, soft piano, brown noise) and short phrases in a calm voice:
  a gentle AI voice, or a parent's own voice if they choose.
- A gentle vibration on each breath in.
- Afterwards, three big faces: "better", "same", "worse". The child taps how they feel.

Section "Three ways calm mode starts":
1. The child taps "Start calm" on the watch.
2. A teacher or parent taps "Start calm" in the Ebb app or on this website.
3. On its own, when the watch senses agitation rising (only if a parent turned this on).

Section "Response steps" (a 3-step diagram):
1. Rising → slow breathing buzz on the wrist.
2. High → calm mode starts by itself.
3. Still high after a minute of calm → "needs an adult" alert to linked adults.

Footnote: "The watch shows a QR code until a parent pairs it. Calm mode ends by itself
after 3 minutes, or when an adult stops it."

=====================================================================
3. How It Works
=====================================================================
Title: "Sense. Calm. Learn."
Four steps (numbered cards):
1. "Set up in minutes" — The parent scans the watch's QR code in the Ebb app, adds the
   child by nickname, and answers a short calm assessment (triggers, sensitivity to sound
   and touch, favourite colours and things, what already helps, what to never do).
2. "AI suggests a calm profile" — Google Gemini turns the answers into a calm profile
   (theme, colours, breathing pace, vibration, sound, message). It can only choose options
   the watch can play. The parent reviews and approves it before it reaches the watch.
   The child's name is never sent to the AI.
3. "Sense and respond" — The watch learns the child's own normal for movement and noise,
   scores agitation against it, and responds in steps (see The Watch).
4. "Learn every week" — After each calm moment Ebb measures agitation before and after and
   how long the child took to settle. Teachers rate "Helped", "Didn't help" or "False
   alarm"; the child taps a face. Ebb uses all three to:
   - tune its sensitivity (a false alarm makes it less sensitive, a helpful start a bit more),
   - pick the scene most likely to help at this time of day, while still trying new ones
     now and then (a learning method called Thompson sampling),
   - forecast the riskiest hours ahead,
   - write a weekly report with patterns, what helps and ideas to try.

Small diagram: Watch → Ebb cloud (Supabase) → Teacher & parent app / website / iMessage.

=====================================================================
4. Who It's For
=====================================================================
Title: "For the child, and the adults around them"
Three cards:
- "Kids (K-12) with special needs" — For children who find big feelings hard to manage,
  including many autistic children and kids with ADHD or sensory processing differences.
  Ebb is calm, predictable and gentle, never punishing.
- "Parents" — Pair the watch, approve the calm profile, choose the voice (a calm AI voice
  or your own), approve this week's 6 scenes, see every calm moment and the weekly report,
  and read the teacher's notes. Turn on auto-start and location only if you want them.
- "Teachers" — Start or stop calm from the class page, see alerts live, rate each calm
  moment, and write a quick journal note with prompts ("What happened before", "What
  helped", "How it ended", "Next time, try").
Line under the cards: "Ebb supports the adults. It never replaces them."

=====================================================================
5. Privacy & Safety
=====================================================================
Title: "Only what helps, nothing more"
Bullet list:
- Children are known by a nickname and age band only. No full names, photos or birthdays.
- The watch never records audio. The microphone only measures how loud the room is.
- Parents give consent when adding a child and can delete data at any time.
- Only the child's parent and the teachers they've linked can see the child's data
  (enforced in the database with row-level security).
- AI: the child's name is removed before anything is sent to Google Gemini (and adult
  names too, in weekly reports). A parent approves every calm profile before it reaches
  the watch.
- Voice cloning only with the parent's explicit consent; the recording itself isn't kept,
  and the cloned voice can be deleted at any time.
- Location is off by default. If a parent turns it on, teachers can see it only on school
  days, 8am–3pm. Location points are deleted after 30 days, and turning location off
  erases them right away.
- Live movement and noise readings are deleted after 2 days.
- Texting: only confirmed phone numbers linked to an Ebb account get answers; calm can't
  be started or stopped by text.
Footnote: "Ebb is a support tool, not a medical device, and doesn't diagnose or treat
any condition."

=====================================================================
6. Help
=====================================================================
Title: "Getting set up"
FAQ (accordion):
- "How do I pair the watch?" — Turn the watch on near Wi-Fi. It shows a QR code. In the
  Ebb iPhone app tap "Pair watch", scan the code, and choose or add your child.
- "How does a teacher join?" — While the watch still shows its QR code after the parent
  pairs it, the teacher scans it in their Ebb app (signed in as a teacher).
- "Which Wi-Fi does the watch need?" — 2.4 GHz Wi-Fi. If your network is 5 GHz only, use a
  phone hotspot with "Maximize Compatibility" turned on.
- "How do I turn on auto-start?" — In the app, open your child's "Live agitation" page and
  switch on Movement and/or Loud room.
- "Can I text Ebb?" — Yes. Add your phone in the app (Account → Add phone). Then text Ebb
  questions like "How was Sam today?", or a note that's shared with your child's team.
- "Can I sign in with my phone number?" — Yes. Choose "Phone" on the sign-in screen and
  enter the code Ebb sends you by iMessage.
- "How do I delete our data?" — Parents can delete their voice and clips in the app, turn
  off location (erases all points), or remove the child, which deletes their data.
Contact line: "Questions? Email hello@useebb.tech" (only if that address exists; otherwise
leave the contact line out).

=====================================================================
Signed-in portals
=====================================================================
Keep the teacher and parent portals exactly as described in docs/lovable-prompt.md
(including its "Adaptive Ebb" section: live agitation board, insights, sensitivity log,
location map). Don't invent data on any page: when there's no data yet, show a friendly
empty state ("No calm moments yet today").
