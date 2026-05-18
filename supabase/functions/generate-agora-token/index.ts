// =============================================================================
// DateNow — Agora RTC token issuer
//
// Signs a short-lived Agora RTC token server-side so AGORA_APP_CERTIFICATE
// never reaches the client. The token is bound to (channel_name, uid) and
// only issued when the caller actually participates in the `calls` row.
//
// Required secrets (set with `supabase secrets set`):
//   - AGORA_APP_ID
//   - AGORA_APP_CERTIFICATE   — NEVER expose anywhere else.
//
// Deploy with:
//   supabase functions deploy generate-agora-token
// =============================================================================

// deno-lint-ignore-file no-explicit-any
import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";
import { RtcRole, RtcTokenBuilder } from "npm:agora-token@2.0.5";

const AGORA_APP_ID = Deno.env.get("AGORA_APP_ID") ?? "";
const AGORA_APP_CERTIFICATE = Deno.env.get("AGORA_APP_CERTIFICATE") ?? "";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";

// 15-minute validity — comfortably above the 5-minute call cap, with
// margin for reconnection.
const TOKEN_TTL_SECONDS = 15 * 60;

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

console.log(
  `[boot] AGORA_APP_ID=${AGORA_APP_ID || "MISSING"} ` +
    `AGORA_APP_CERTIFICATE=${
      AGORA_APP_CERTIFICATE ? "set" : "MISSING"
    }`,
);

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

  const callId = (body?.call_id ?? "").toString();
  const channelName = (body?.channel_name ?? "").toString();
  const uidRaw = body?.uid;
  if (!callId || !channelName) {
    return json({ error: "missing_call_id_or_channel" }, 400);
  }
  const uid = typeof uidRaw === "number" ? Math.trunc(uidRaw) : NaN;
  if (!Number.isFinite(uid) || uid < 0 || uid > 0x7fffffff) {
    return json({ error: "invalid_uid" }, 400);
  }
  if (channelName.length > 64) {
    return json({ error: "invalid_channel_name" }, 400);
  }

  // Authorisation — the caller must be a participant of THIS call, and the
  // channel name passed must match the row. Prevents minting tokens for
  // arbitrary channels or calls the user isn't in.
  const { data: callRow, error: callErr } = await supabase
    .from("calls")
    .select("id, caller_id, callee_id, channel_name, status")
    .eq("id", callId)
    .maybeSingle();
  if (callErr) {
    return json({ error: "call_lookup_failed", detail: callErr.message }, 500);
  }
  if (!callRow) {
    return json({ error: "call_not_found" }, 404);
  }
  if (callRow.caller_id !== userId && callRow.callee_id !== userId) {
    return json({ error: "not_a_participant" }, 403);
  }
  if (callRow.channel_name !== channelName) {
    return json({ error: "channel_mismatch" }, 403);
  }
  if (callRow.status === "ended") {
    return json({ error: "call_already_ended" }, 410);
  }

  const now = Math.floor(Date.now() / 1000);
  const expiresAt = now + TOKEN_TTL_SECONDS;

  let token: string;
  try {
    token = RtcTokenBuilder.buildTokenWithUid(
      AGORA_APP_ID,
      AGORA_APP_CERTIFICATE,
      channelName,
      uid,
      RtcRole.PUBLISHER,
      expiresAt,
      expiresAt,
    );
  } catch (signErr) {
    console.error(`[token-fail] channel=${channelName} uid=${uid}:`, signErr);
    return json({ error: "token_sign_failed" }, 500);
  }

  console.log(
    `[token-ok] caller=${userId} call=${callId} channel=${channelName} ` +
      `uid=${uid} tokenLen=${token.length} expiresAt=${expiresAt}`,
  );

  return json({
    token,
    appId: AGORA_APP_ID,
    channelName,
    uid,
    expiresAt,
  });
});
