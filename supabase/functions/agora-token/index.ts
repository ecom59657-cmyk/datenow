// =============================================================================
// DateNow — Agora token issuer
//
// Signs short-lived Agora RTC tokens server-side so the App Certificate
// never leaks to the client. The function is auth-gated: callers must
// present a Supabase access token (the SDK does this automatically when
// you use `client.functions.invoke`).
//
// Required secrets (set with `supabase secrets set`):
//   - AGORA_APP_ID            — also available client-side, but we keep
//                               it server-side too so the token is bound
//                               to the same value we sign with.
//   - AGORA_APP_CERTIFICATE   — NEVER expose this anywhere else.
//
// Deploy with:
//   supabase functions deploy agora-token --no-verify-jwt
//
// (We do the JWT check ourselves with `supabase.auth.getUser()` so we can
// return a friendlier 401 instead of GoTrue's generic error.)
// =============================================================================

// deno-lint-ignore-file no-explicit-any
import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";
import { RtcTokenBuilder, RtcRole } from "npm:agora-token@2.0.5";

const AGORA_APP_ID = Deno.env.get("AGORA_APP_ID") ?? "";
const AGORA_APP_CERTIFICATE = Deno.env.get("AGORA_APP_CERTIFICATE") ?? "";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: CORS_HEADERS });
  }
  if (req.method !== "POST") {
    return json({ error: "method_not_allowed" }, 405);
  }

  if (!AGORA_APP_ID || !AGORA_APP_CERTIFICATE) {
    return json({ error: "agora_not_configured" }, 500);
  }

  const authHeader = req.headers.get("Authorization") ?? "";
  if (!authHeader.startsWith("Bearer ")) {
    return json({ error: "unauthorized" }, 401);
  }

  // Resolve the caller. Using the anon key + the user's token gives us
  // an RLS-bound client (`auth.uid()` returns the caller's id).
  const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
  });

  const { data: userResult, error: userError } = await supabase.auth.getUser();
  if (userError || !userResult?.user) {
    return json({ error: "unauthorized" }, 401);
  }
  const userId = userResult.user.id;

  let body: any;
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid_body" }, 400);
  }

  const channelName = (body?.channelName ?? "").toString();
  const uidRaw = body?.uid;
  if (!channelName || channelName.length > 64) {
    return json({ error: "invalid_channel_name" }, 400);
  }

  // We expect the client to derive uid from its own user id (uint32 hash).
  // Accept it as a number, then clamp into Agora's valid range.
  const uid = typeof uidRaw === "number" ? Math.trunc(uidRaw) : NaN;
  if (!Number.isFinite(uid) || uid < 0 || uid > 0x7fffffff) {
    return json({ error: "invalid_uid" }, 400);
  }

  // Light authorisation: the channel name SHOULD include the caller's
  // user id (we use `dn-<sortedConcat>` client-side). If it doesn't, the
  // caller is trying to join a channel that isn't theirs.
  const sanitizedUserId = userId.replace(/-/g, "");
  if (!channelName.includes(sanitizedUserId)) {
    return json({ error: "channel_not_for_user" }, 403);
  }

  // Token valid for 10 minutes — well above the 5-minute call cap, with a
  // margin for connection retries.
  const expirySeconds = 600;
  const now = Math.floor(Date.now() / 1000);
  const privilegeExpiredTs = now + expirySeconds;

  const token = RtcTokenBuilder.buildTokenWithUid(
    AGORA_APP_ID,
    AGORA_APP_CERTIFICATE,
    channelName,
    uid,
    RtcRole.PUBLISHER,
    privilegeExpiredTs,
    privilegeExpiredTs,
  );

  return json({
    token,
    appId: AGORA_APP_ID,
    channelName,
    uid,
    expiresAt: privilegeExpiredTs,
  });
});
