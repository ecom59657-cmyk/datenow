// =============================================================================
// DateNow — accept-match
//
// L'utilisateur (caller ou callee) accepte le match proposé : flip de son
// flag ready. Si les deux sont ready, la session passe en 'live' et
// `room_expires_at` est armé (30 min).
//
// Body  : { call_id: uuid }
// 200   : { state: 'waiting' | 'live', both_ready: boolean, channel_name: string }
// 401 unauthorized | 403 not_a_participant | 404 call_not_found
// 409 call_not_waiting | 410 accept_window_expired
// =============================================================================

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { handlePreflight } from "../_shared/cors.ts";
import { ok, err, fromPgError } from "../_shared/errors.ts";
import { requireUser } from "../_shared/auth.ts";
import { userClient } from "../_shared/supabase.ts";
import { makeLogger, newRequestId } from "../_shared/logger.ts";

const UUID_RX = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

serve(async (req) => {
  const pre = handlePreflight(req); if (pre) return pre;
  if (req.method !== "POST") return err(405, "method_not_allowed");

  const log = makeLogger("accept-match", newRequestId());
  const client = userClient(req);
  const auth = await requireUser(client);
  if (auth.response) return auth.response;

  const body = await req.json().catch(() => ({} as any));
  const callId = String(body.call_id ?? "");
  if (!UUID_RX.test(callId)) return err(400, "invalid_call_id");

  const { data, error } = await client
    .rpc("mm_accept_match", { p_call_id: callId })
    .single();

  if (error) {
    log.warn("rpc_failed", { code: error.code, message: error.message });
    return fromPgError(error);
  }

  const row = data as any;
  log.info("accepted", { user: auth.user.id, call: callId, both: row?.both_ready });
  return ok({
    state: row?.state,
    both_ready: !!row?.both_ready,
    channel_name: row?.channel_name,
  });
});
