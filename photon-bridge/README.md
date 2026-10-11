# Ebb iMessage bridge (Photon)

A small Node process that runs on a Mac and connects Ebb to iMessage through
[Photon Spectrum](https://photon.codes). Sending a text needs Photon's live SDK
session, so this runs as a long-lived process rather than an edge function.

- **Inbound:** every iMessage DM to the Ebb line goes to the `messaging`
  edge function (`/messaging/inbound`). It answers questions about a child,
  saves notes to the journal, and returns replies that the bridge sends back.
- **Outbound:** every 3 s the bridge claims queued texts (login codes from the
  `sms-hook` function, journal relays to parents/teachers) from
  `/messaging/outbox`, sends them, and reports back to `/messaging/sent`.

## Run

Needs Node 20.12+ (uses `process.loadEnvFile`).

```sh
cd photon-bridge
npm install
cp .env.example .env      # then fill in the three secrets
npm start                 # or: node index.js
```

Leave it running (a spare Terminal tab, or `caffeinate -i npm start` so the
Mac doesn't sleep). Codes and relays queue in Supabase while it's down; codes
expire after 10 minutes, relays after a day.

## Config (.env)

| Name | What |
|---|---|
| `SPECTRUM_PROJECT_ID` / `SPECTRUM_PROJECT_SECRET` | Photon project credentials |
| `BRIDGE_SECRET` | Random string; must equal the `BRIDGE_SECRET` edge function secret |
| `SUPABASE_FUNCTIONS_URL` | `https://pchbznvjjmfcfjwrbmvj.supabase.co/functions/v1` |
| `POLL_MS` | Optional outbox poll interval, default 3000 |

`.env` is gitignored. Logs show only the last two digits of phone numbers and
never message text.

Full setup (Supabase dashboard, hook secret, testing): [../docs/photon-setup.md](../docs/photon-setup.md).
