// =============================================================================
// DateNow — heartbeat-presence
//
// Battement client (toutes les 12 s en pratique). Rafraîchit `heartbeat_at`
// et `expires_at` de la file + `updated_at` de la présence.
//
// 200 : { queue_alive: boolean, presence_status: string }
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

  const log = makeLogger("heartbeat", newRequestId());
  const client = userClient(req);
  const auth = await requireUser(client);
  if (auth.response) return auth.response;

  const { data, error } = await client.rpc("mm_heartbeat").single();
  if (error) {
    log.warn("rpc_failed", { code: error.code, message: error.message });
    return fromPgError(error);
  }

  const row = data as any;
  return ok({
    queue_alive: !!row?.queue_alive,
    presence_status: row?.presence_status ?? "offline",
  });
});
