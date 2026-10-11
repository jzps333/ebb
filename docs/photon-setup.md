# iMessage with Photon: setup

Ebb texts parents and teachers over iMessage through [Photon](https://photon.codes):

- **Login codes.** Phone sign-in and "add phone" codes arrive as an iMessage
  from the Ebb line (Supabase Auth Send SMS hook → `sms-hook` → queue → bridge).
- **Journal relays.** When a teacher writes a journal entry or anyone comments,
  every *other* adult linked to that child who has a confirmed phone gets
  `Ms. Rivera (Sam's teacher): …` (trigger on `journal_entries` /
  `journal_comments` → queue → bridge).
- **Texting back.** A parent or teacher can text the line:
  - a question ("How was Sam's morning?") is answered from that child's data
    (calm moments of the last 14 days with outcomes, 28-day stats, latest weekly
    report, last 7 days of journal), using Gemini. The child's nickname is replaced with
    `[child]` before anything goes to Gemini.
  - a note ("He slept badly last night") is saved to the journal and relayed:
    a teacher's note becomes their journal entry for today (or a comment on it);
    a parent's note becomes a comment on today's entry, or, if no teacher has
    written today, is texted straight to the teachers without being saved.
  - "start/stop calm" is refused: calm control stays in the app and on the watch.
  - With several children, start a text with the name (`Sam: how was today?`)
    or text just the name to switch. Replying to a relay talks about that child.

```
Auth (OTP) ─▶ sms-hook ─┐
journal insert trigger ─┼─▶ private.outbound_texts ◀─ messaging/outbox ◀─┐
                        │                                                  │ every 3 s
iMessage ◀──────────────┴──────────── photon-bridge (Mac, Spectrum SDK) ───┘
iMessage ──▶ photon-bridge ──▶ messaging/inbound ──▶ Gemini + journal ──▶ replies
```

Database objects: `supabase/migrations/0020_photon_messaging.sql` (applied).
Edge functions: `sms-hook`, `messaging` (both deployed, `verify_jwt = false`).

## 1. Secrets

Set these as Edge Function secrets (Dashboard → Edge Functions → Secrets, or
`supabase secrets set NAME=value --project-ref pchbznvjjmfcfjwrbmvj`):

| Secret | Value |
|---|---|
| `BRIDGE_SECRET` | `openssl rand -hex 32` (at least 16 chars). Same value goes in `photon-bridge/.env`. |
| `SEND_SMS_HOOK_SECRET` | The `v1,whsec_…` secret generated in step 2. |
| `GEMINI_API_KEY` | Already set for `generate-profile`; reused. `GEMINI_MODEL` optional. |

The Photon credentials (`SPECTRUM_PROJECT_ID`, `SPECTRUM_PROJECT_SECRET`) are
only needed by the bridge, in `photon-bridge/.env`.

## 2. Supabase dashboard

1. **Authentication → Sign In / Providers → Phone**: enable. No SMS provider
   (Twilio etc.) is needed: the hook replaces it. Leave "Confirm phone" on.
2. **Authentication → Hooks → Add hook → Send SMS hook**:
   - Type: **HTTPS**
   - URL: `https://pchbznvjjmfcfjwrbmvj.supabase.co/functions/v1/sms-hook`
   - Click **Generate secret**, copy it (`v1,whsec_…`), save the hook.
3. Set that value as the `SEND_SMS_HOOK_SECRET` edge function secret
   (step 1). Until it is set, the hook returns "Text messages are not set up yet."

## 3. Photon

1. Sign in at photon.codes with the hackathon account, open (or create) the
   project, and turn on **iMessage**.
2. Copy the **project ID** and **project secret** into `photon-bridge/.env`.
3. Note the Ebb line's number/address shown for iMessage; that's the number
   parents and teachers text.

## 4. Run the bridge

```sh
cd photon-bridge
npm install
cp .env.example .env   # fill SPECTRUM_PROJECT_ID, SPECTRUM_PROJECT_SECRET, BRIDGE_SECRET
npm start
```

Expect `Ebb bridge connected to Photon.` Keep it running while demoing.

## 5. App side (iOS / web)

Phone sign-in (new or existing phone user):

```swift
try await supabase.auth.signInWithOTP(phone: "+15551234567")
try await supabase.auth.verifyOTP(phone: "+15551234567", token: code, type: .sms)
```

Link a phone to an existing (email) account: Account → Add phone:

```swift
try await supabase.auth.update(user: UserAttributes(phone: "+15551234567"))
try await supabase.auth.verifyOTP(phone: "+15551234567", token: code, type: .phoneChange)
```

(JS: `signInWithOtp({ phone })`, `verifyOtp({ phone, token, type: 'sms' })`,
`updateUser({ phone })`, `verifyOtp({ phone, token, type: 'phone_change' })`.)

Only confirmed phones (`auth.users.phone_confirmed_at`) receive relays or can
text the line. Use E.164 (`+1…`). A new phone-only sign-up gets a `parent`
profile (the sign-up trigger's default) unless `data: { role: "teacher" }` is
passed.

## 6. Test script

1. Bridge running, secrets set, hook configured.
2. In the app, sign in as the parent → Account → Add phone → enter your
   iPhone number. An iMessage "Your Ebb code is 123456…" arrives within ~3 s.
   Enter it.
3. Do the same for a teacher account linked to the child, with a second phone.
4. As the teacher, write a journal entry in the app → the parent's phone gets
   `Ms. Rivera (Sam's teacher) wrote today's note: …`.
5. From the parent's phone, reply `Thanks! He slept badly last night.` → the
   parent gets "Added to Sam's journal…", the teacher gets
   `Alex (Sam's parent): Thanks! He slept badly last night.`, and the comment
   shows in the app.
6. From the parent's phone: `How was Sam's day?` → a short answer with numbers.
7. `Start calm for Sam` → told to use the app or the watch.
8. Text from a number that isn't linked → "This number isn't linked to Ebb yet…"

Checking the queue (SQL editor):

```sql
select id, kind, right(to_phone, 2) as to_last2, created_at, sent_at, attempts, error
from private.outbound_texts order by id desc limit 20;
```

## Notes and limits

- Bridge down: texts wait in `private.outbound_texts`. Codes older than
  10 minutes and relays older than a day are not sent. 5 attempts max.
- A message id is processed once (`private.processed_texts`); more than 30
  texts an hour from one number get a "slow down" reply.
- Relay bodies are cut to 320 characters; open the app for the full entry.
- `sms-hook` sends phone-change codes to `user.new_phone` when present,
  otherwise `user.phone`.
- All `public.ebb_text_*` functions are executable by `service_role` only.
