# Ebb

Ebb: a calming smartwatch for K-12 special needs students. Teachers start calm mode from their phone.

A teacher taps **Start calm** on their phone or laptop and the student's LilyGO T-Watch S3 Plus shows a breathing circle in the child's theme, pulses gently and plays the child's chosen sound within a few seconds. The watch can also start on its own when it senses repetitive motion or a loud room. Whenever calm mode starts, the teacher and the parent both see it live.

Ebb is a support tool that works alongside teachers and therapists. It is not a medical device and does not diagnose or treat anything.

**Demo video:** _link coming_

## Architecture

```
Teacher taps Start calm ──insert──▶ commands table (Supabase)
                                         │
Watch ── GET device-api/poll every 3 s ──┘  ──▶ runs calm mode
  │
  └── POST device-api/events ──▶ events table ──Realtime──▶ teacher + parent pages
Parent assessment ──▶ generate-profile (Claude) ──▶ draft profile ──▶ parent approves ──▶ watch downloads it
```

The AI key lives only in the `generate-profile` Edge Function. See [docs/architecture.md](docs/architecture.md).

## Repo layout

| Folder | What | Owner |
|---|---|---|
| `firmware/` | Arduino sketch for the watch | Teammate 1 |
| `supabase/` | Database, RLS, Edge Functions | Teammate 2 |
| `web/` | Next.js website for teachers and parents | Teammate 2 |
| `scripts/` | `simulate_watch.py` to test without a watch | Teammate 2 |
| `docs/` | Architecture, assessment questions, privacy, demo script | Both |

## Setup

- **Watch:** see [firmware/README.md](firmware/README.md).
- **Supabase + website:** _steps coming as Teammate 2 builds them._

## Privacy

No audio is ever recorded or sent; the microphone only produces a loudness number on the watch. Students have no account; only a nickname and age band are stored. See [docs/privacy.md](docs/privacy.md).

## Team

_Names coming._

## Built before vs during the event

_To fill in: what was prepped before the hackathon (plan, hardware setup) and what was built during it._
