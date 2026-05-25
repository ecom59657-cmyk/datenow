// =============================================================================
// DateNow — message-notification Edge Function (APNs HTTP/2)
//
// Triggered by a Supabase Database Webhook on INSERT into
// `public.messages`. Looks up the recipient's device_tokens row(s) and
// sends a silent, content-minimal push to each via Apple's HTTP/2 APNs
// endpoint.
//
// Privacy: the push body carries ONLY the sender's first name. The
// message text is never included. The recipient's app fetches the
// real conversation via Supabase Realtime / mark-as-read when the user
// taps the notification.
//
// Required Supabase secrets (`supabase secrets set ...`):
//   APNS_KEY            — full contents of AuthKey_XXXX.p8 (PEM)
//   APNS_KEY_ID         — 10-char key id shown in Apple Developer
//   APNS_TEAM_ID        — 10-char team id
//   APNS_BUNDLE_ID      — com.datenow.app
//   APNS_HOST           — api.push.apple.com (prod) or api.sandbox.push.apple.com
//   SUPABASE_URL        — auto-injected
//   SUPABASE_SERVICE_ROLE_KEY — auto-injected
//
// Until those secrets are present the function returns 503 — Apple
// never delivers anything and DateNow keeps working (the unread badge
// is enough). See docs/PUSH_NOTIFICATIONS_SETUP.md.
// =============================================================================

import { create as createJwt, getNumericDate } from "https://deno.land/x/djwt@v3.0.2/mod.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

interface MessagePayload {
  type: "INSERT";
  table: "messages";
  record: {
    id: string;
    conversation_id: string;
    sender_id: string;
    body: string;
    created_at: string;
  };
  schema: "public";
  old_record: null;
}

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") {
    return new Response("method not allowed", { status: 405, headers: CORS });
  }

  // Read required APNs secrets up front — if any is missing we bail out
  // 503 and the call to the webhook fails fast (Supabase will surface
  // the error in the dashboard).
  const apnsKey = Deno.env.get("APNS_KEY");
  const apnsKeyId = Deno.env.get("APNS_KEY_ID");
  const apnsTeamId = Deno.env.get("APNS_TEAM_ID");
  const apnsBundleId = Deno.env.get("APNS_BUNDLE_ID");
  const apnsHost =
    Deno.env.get("APNS_HOST") ?? "api.push.apple.com";
  if (!apnsKey || !apnsKeyId || !apnsTeamId || !apnsBundleId) {
    return new Response(
      JSON.stringify({
        error: "apns_not_configured",
        hint: "Set APNS_KEY / APNS_KEY_ID / APNS_TEAM_ID / APNS_BUNDLE_ID secrets.",
      }),
      { status: 503, headers: { ...CORS, "Content-Type": "application/json" } },
    );
  }

  const payload = (await req.json()) as MessagePayload;
  if (payload?.table !== "messages" || payload?.type !== "INSERT") {
    return new Response("ignored", { status: 200, headers: CORS });
  }

  const supa = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  // Resolve recipient (the other participant of the conversation) and
  // the sender's first name. Both queries bypass RLS via service-role.
  const { data: convo, error: convErr } = await supa
    .from("conversations")
    .select("id, user_a_id, user_b_id")
    .eq("id", payload.record.conversation_id)
    .single();
  if (convErr || !convo) {
    return new Response("conversation not found", { status: 404, headers: CORS });
  }
  const recipientId =
    convo.user_a_id === payload.record.sender_id
      ? convo.user_b_id
      : convo.user_a_id;
  if (recipientId === payload.record.sender_id) {
    return new Response("self-send, no push", { status: 200, headers: CORS });
  }

  const { data: sender } = await supa
    .from("profiles")
    .select("first_name")
    .eq("id", payload.record.sender_id)
    .single();
  const firstName = (sender?.first_name as string | undefined)?.trim() || "Quelqu'un";

  // Look up every iOS device token registered for the recipient.
  const { data: tokens } = await supa
    .from("device_tokens")
    .select("token")
    .eq("user_id", recipientId)
    .eq("platform", "ios");
  if (!tokens || tokens.length === 0) {
    return new Response("no device tokens", { status: 200, headers: CORS });
  }

  // Sign an APNs JWT (ES256 over the .p8 key). Apple expects this as
  // the `authorization: bearer <jwt>` header on the HTTP/2 POST.
  const keyPem = apnsKey.includes("-----BEGIN")
    ? apnsKey
    : `-----BEGIN PRIVATE KEY-----\n${apnsKey}\n-----END PRIVATE KEY-----`;
  const keyPkcs8 = pemToArrayBuffer(keyPem);
  const cryptoKey = await crypto.subtle.importKey(
    "pkcs8",
    keyPkcs8,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  const jwt = await createJwt(
    { alg: "ES256", typ: "JWT", kid: apnsKeyId },
    { iss: apnsTeamId, iat: getNumericDate(0) },
    cryptoKey,
  );

  const apnsPayload = JSON.stringify({
    aps: {
      alert: { title: "DateNow", body: firstName },
      sound: "default",
    },
    conversation_id: payload.record.conversation_id,
    sender_id: payload.record.sender_id,
    route: `/messages/${payload.record.conversation_id}`,
  });

  // Fire one POST per token. Failures don't block the others.
  await Promise.allSettled(
    tokens.map(({ token }) =>
      fetch(`https://${apnsHost}/3/device/${token}`, {
        method: "POST",
        headers: {
          "authorization": `bearer ${jwt}`,
          "apns-topic": apnsBundleId,
          "apns-push-type": "alert",
          "apns-priority": "10",
          "content-type": "application/json",
        },
        body: apnsPayload,
      }),
    ),
  );

  return new Response(JSON.stringify({ pushed: tokens.length }), {
    status: 200,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
});

// Minimal PEM → ArrayBuffer helper for the .p8 PKCS8 key.
function pemToArrayBuffer(pem: string): ArrayBuffer {
  const b64 = pem
    .replace(/-----BEGIN [^-]+-----/g, "")
    .replace(/-----END [^-]+-----/g, "")
    .replace(/\s+/g, "");
  const bin = atob(b64);
  const buf = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) buf[i] = bin.charCodeAt(i);
  return buf.buffer;
}
