// =============================================================================
// DateNow — leave-queue
//
// L'utilisateur quitte explicitement la file. Idempotent : retourne
// `left=false` s'il n'était pas en file. Met aussi presence à 'online'.
//
// 200 : { left: boolean }
// 401 : { error: "unauthorized" }
// =============================================================================

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { handlePreflight } from "../_shared/cors.ts";
import { ok, err, fromPgError } from "../_shared/errors.ts";
import { requireUser } from "../_shared/auth.ts";
import { userClient } from "../_shared/supabase.ts";
import { makeLogger, newRequestId } from "../_shared/logger.ts";

serve(async (req) => {
  const pre = handlePreflight(req); if (pre) return pre;
  if (req.method !== "POST") return err(405, "method_not_allowed");

  const log = makeLogger("leave-queue", newRequestId());
  const client = userClient(req);
  const auth = await requireUser(client);
  if (auth.response) return auth.response;

  const { data, error } = await client.rpc("mm_leave_queue");
  if (error) {
    log.warn("rpc_failed", { code: error.code, message: error.message });
    return fromPgError(error);
  }

  log.info("left", { user: auth.user.id, was_in_queue: !!data });
  return ok({ left: !!data });
});
