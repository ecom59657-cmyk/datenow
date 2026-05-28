// =============================================================================
// DateNow — cancel-session
//
// Termine une session live ou waiting (hangup, sortie utilisateur).
//
// Body  : { call_id: uuid, reason?: 'user_cancel' | 'normal_end' | 'cancelled' }
// 200   : { ended: boolean }
// 401 unauthorized | 403 not_a_participant | 404 call_not_found
// =============================================================================

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { handlePreflight } from "../_shared/cors.ts";
import { ok, err, fromPgError } from "../_shared/errors.ts";
import { requireUser } from "../_shared/auth.ts";
import { userClient } from "../_shared/supabase.ts";
import { makeLogger, newRequestId } from "../_shared/logger.ts";

const UUID_RX = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const ALLOWED_REASONS = new Set(["user_cancel", "normal_end", "cancelled"]);

serve(async (req) => {
  const pre = handlePreflight(req); if (pre) return pre;
  if (req.method !== "POST") return err(405, "method_not_allowed");

  const log = makeLogger("cancel-session", newRequestId());
  const client = userClient(req);
  const auth = await requireUser(client);
  if (auth.response) return auth.response;

  const body = await req.json().catch(() => ({} as any));
  const callId = String(body.call_id ?? "");
  if (!UUID_RX.test(callId)) return err(400, "invalid_call_id");

  const reason = ALLOWED_REASONS.has(body.reason) ? body.reason : "user_cancel";

  const { data, error } = await client
    .rpc("mm_cancel_session", { p_call_id: callId, p_reason: reason });

  if (error) {
    log.warn("rpc_failed", { code: error.code, message: error.message });
    return fromPgError(error);
  }

  log.info("ended", { user: auth.user.id, call: callId, reason });
  return ok({ ended: !!data });
});
