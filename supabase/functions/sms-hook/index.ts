// sms-hook: Supabase Auth "Send SMS" HTTP hook. Instead of an SMS provider,
// Auth hands us the login / phone-confirm code and we queue it as an iMessage;
// the Photon bridge on the Mac sends it.
//
// POST /functions/v1/sms-hook   (called by Supabase Auth, never by the app)
//   headers: webhook-id, webhook-timestamp, webhook-signature (Standard Webhooks)
//   body:    { user: { phone, new_phone?, ... }, sms: { otp } }
//   -> 200 {}
//
// SEND_SMS_HOOK_SECRET is the "v1,whsec_<base64>" value the dashboard
// generates (several may be joined with "|" while rotating).
// verify_jwt is off: the signature is the authentication.

import { createClient } from "npm:@supabase/supabase-js@2";
import { Webhook } from "npm:standardwebhooks@1.0.0";

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

// Auth hook errors are shown to the user, so keep them plain.
function hookError(message: string, status = 500): Response {
  return json({ error: { http_code: status, message } }, status);
}

function verify(raw: string, headers: Headers): Record<string, unknown> | null {
  const secrets = (Deno.env.get("SEND_SMS_HOOK_SECRET") ?? "")
    .split("|")
    .map((s) => s.trim().replace(/^v1,whsec_/, ""))
    .filter(Boolean);
  const h = {
    "webhook-id": headers.get("webhook-id") ?? "",
    "webhook-timestamp": headers.get("webhook-timestamp") ?? "",
    "webhook-signature": headers.get("webhook-signature") ?? "",
  };
  for (const secret of secrets) {
    try {
      return new Webhook(secret).verify(raw, h) as Record<string, unknown>;
    } catch {
      // try the next secret
    }
  }
  return null;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "use POST" }, 405);
  if (!Deno.env.get("SEND_SMS_HOOK_SECRET")) {
    console.error("sms-hook: SEND_SMS_HOOK_SECRET is not set");
    return hookError("Text messages are not set up yet.");
  }

  const raw = await req.text();
  const payload = verify(raw, req.headers);
  if (!payload) return hookError("Bad signature.", 401);

  const user = (payload.user ?? {}) as Record<string, unknown>;
  const sms = (payload.sms ?? {}) as Record<string, unknown>;
  const otp = typeof sms.otp === "string" ? sms.otp : "";
  // A phone change (updateUser({ phone })) sends the code to the NEW number,
  // which Auth puts in user.new_phone; sign-in / sign-up codes go to user.phone.
  const phone = [sms.phone, user.new_phone, user.phone].find((p) => typeof p === "string" && p.trim() !== "") as
    | string
    | undefined;
  if (!otp || !phone) return hookError("No phone number or code to send.", 400);

  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false },
  });
  const { data, error } = await admin.rpc("ebb_text_enqueue_otp", {
    p_phone: phone,
    p_body: `Your Ebb code is ${otp}. It expires in 10 minutes.`,
  });
  if (error || data == null) {
    // No phone digits or code in logs.
    console.error("sms-hook enqueue failed", error?.code ?? "invalid phone");
    return hookError("Could not send the code. Check the phone number and try again.");
  }
  return json({});
});
