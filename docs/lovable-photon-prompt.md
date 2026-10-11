Use the Photon (iMessage) connector to be Ebb's texting line. The Ebb backend already
exists in the connected Supabase project; you only connect Photon to it. Do NOT create or
change any database tables, policies or migrations.

Build two Supabase edge functions (both with verify_jwt = false):

1. `photon-send` — sends one iMessage.
   - Accepts POST JSON `{ "to_phone": "+15551234567", "body": "text", "kind": "otp" | "relay" | "reply" }`.
   - Require header `x-bridge-secret` to equal the existing secret `BRIDGE_SECRET`
     (already set in this project's edge function secrets). Compare in constant time.
     Wrong or missing → 401 `{ "error": "unauthorized" }`.
   - Open (or reuse) the direct-message conversation with `to_phone` using the Photon
     connector and send `body` as plain text. Return 200 `{ "ok": true }` on success,
     502 `{ "error": "..." }` if Photon fails.
   - Never log phone numbers or message text (log only the last 2 digits).

2. Inbound texts (the Photon webhook / message handler):
   - For each inbound iMessage DM with text content, skip it if the sender is not a phone
     number (for example an email handle containing "@"), and skip our own outbound echoes.
   - POST to `https://pchbznvjjmfcfjwrbmvj.supabase.co/functions/v1/messaging/inbound`
     with header `x-bridge-secret: <BRIDGE_SECRET>` and JSON
     `{ "from": "<sender phone, E.164>", "text": "<message text>", "message_id": "<Photon message id>" }`.
   - The response is `{ "replies": ["...", ...] }`. Send each reply back into the same
     conversation, in order. If the call fails, reply once:
     "Sorry, something went wrong on our side. Please try again in a bit."
   - Acknowledge the webhook quickly (2xx); verify Photon's webhook signature if the
     connector provides one.

That's all. The backend decides everything else: it answers parents' and teachers'
questions about their child, saves notes to the journal and relays them to the other
adults, and sends sign-in codes. Login codes and relays are pushed to `photon-send`
automatically.
