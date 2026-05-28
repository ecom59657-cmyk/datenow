// =============================================================================
// DateNow — create-agora-room
//
// Orchestrateur du démarrage Agora :
//   1. Vérifie que la session est en état utilisable (waiting avec son
//      propre ready=true, OU live).
//   2. Délègue la signature du token à l'Edge Function existante
//      `generate-agora-token` (jamais touchée, jamais dupliquée).
//
// Body  : { call_id: uuid, uid: int32 }
// 200   : { token, appId, channelName, uid, expiresAt }   (proxie 1:1)
// 401 unauthorized | 403 not_a_participant | 404 call_not_found
// 409 call_not_ready  ←  la session n'est pas en état d'ouvrir la room
// 5xx selon les remontées de generate-agora-token
// =============================================================================

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { handlePreflight, CORS_HEADERS } from "../_shared/cors.ts";
import { ok, err } from "../_shared/errors.ts";
import { requireUser } from "../_shared/auth.ts";
import { userClient } from "../_shared/supabase.ts";
import { makeLogger, newRequestId } from "../_shared/logger.ts";

const UUID_RX = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";

serve(async (req) => {
  const pre = handlePreflight(req); if (pre) return pre;
  if (req.method !== "POST") return err(405, "method_not_allowed");

  const log = makeLogger("create-agora-room", newRequestId());
  const client = userClient(req);
  const auth = await requireUser(client);
  if (auth.response) return auth.response;

  const body = await req.json().catch(() => ({} as any));
  const callId = String(body.call_id ?? "");
  if (!UUID_RX.test(callId)) return err(400, "invalid_call_id");
  const uid = Number.isFinite(body.uid) ? Math.trunc(body.uid) : NaN;
  if (!Number.isInteger(uid) || uid < 0 || uid > 0x7fffffff) {
    return err(400, "invalid_uid");
  }

  // 1) Pré-conditions : RLS filtre déjà les calls non-participants.
  const { data: call, error: callErr } = await client
    .from("calls")
    .select("id, caller_id, callee_id, channel_name, status, caller_ready, callee_ready")
    .eq("id", callId)
    .maybeSingle();

  if (callErr) {
    log.error("call_lookup_failed", { code: callErr.code, message: callErr.message });
    return err(500, "call_lookup_failed");
  }
  if (!call) return err(404, "call_not_found");

  const isCaller = call.caller_id === auth.user.id;
  const isCallee = call.callee_id === auth.user.id;
  if (!isCaller && !isCallee) return err(403, "not_a_participant");

  const selfReady = isCaller ? call.caller_ready : call.callee_ready;
  const ready =
    call.status === "live" ||
    (call.status === "waiting" && selfReady === true);
  if (!ready) {
    log.warn("call_not_ready", {
      call: callId, status: call.status, selfReady,
    });
    return err(409, "call_not_ready");
  }
  if (!call.channel_name) {
    log.error("channel_missing", { call: callId });
    return err(500, "channel_missing");
  }

  // 2) Délégation à generate-agora-token (réutilise sa logique de
  //    signature, son audit et ses contrôles serveur).
  const tokenUrl = `${SUPABASE_URL}/functions/v1/generate-agora-token`;
  const authHeader = req.headers.get("Authorization") ?? "";
  const apikey = req.headers.get("apikey") ?? "";

  const proxyResp = await fetch(tokenUrl, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: authHeader,
      apikey,
    },
    body: JSON.stringify({
      call_id: callId,
      channel_name: call.channel_name,
      uid,
    }),
  });

  const text = await proxyResp.text();
  if (!proxyResp.ok) {
    log.warn("token_proxy_failed", { status: proxyResp.status, body: text.slice(0, 300) });
    return new Response(text, {
      status: proxyResp.status,
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    });
  }

  log.info("room_ready", { call: callId, status: call.status });
  return ok(JSON.parse(text));
});
