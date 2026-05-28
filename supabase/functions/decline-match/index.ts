// =============================================================================
// DateNow — decline-match
//
// L'utilisateur refuse explicitement le match proposé. La session passe
// en 'ended' (end_reason='declined') et l'autre user est ré-injecté en file.
//
// Body  : { call_id: uuid, reason?: string }
// 200   : { declined: boolean }
// 401 unauthorized | 403 not_a_participant | 404 call_not_found
// =============================================================================

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { handlePreflight } from "../_shared/cors.ts";
import { ok, err, fromPgError } from "../_shared/errors.ts";
import { requireUser } from "../_shared/auth.ts";
import { userClient } from "../_shared/supabase.ts";
import { makeLogger, newRequestId } from "../_shared/logger.ts";

const UUID_RX = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MAX_REASON = 200;

serve(async (req) => {
  const pre = handlePreflight(req); if (pre) return pre;
  if (req.method !== "POST") return err(405, "method_not_allowed");

  const log = makeLogger("decline-match", newRequestId());
  const client = userClient(req);
  const auth = await requireUser(client);
  if (auth.response) return auth.response;

  const body = await req.json().catch(() => ({} as any));
  const callId = String(body.call_id ?? "");
  if (!UUID_RX.test(callId)) return err(400, "invalid_call_id");

  const reason = typeof body.reason === "string"
    ? body.reason.slice(0, MAX_REASON)
    : null;

  const { data, error } = await client
    .rpc("mm_decline_match", { p_call_id: callId, p_reason: reason });

  if (error) {
    log.warn("rpc_failed", { code: error.code, message: error.message });
    return fromPgError(error);
  }

  log.info("declined", { user: auth.user.id, call: callId, ok: !!data });
  return ok({ declined: !!data });
});
