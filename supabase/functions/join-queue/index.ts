// =============================================================================
// DateNow — join-queue
//
// L'utilisateur authentifié rejoint la file d'attente du matching temps réel.
// Idempotent : un upsert refresh expires_at + heartbeat_at.
//
// Body  : { client_id?: string }
// 200   : { queue_id: uuid, expires_at: iso, joined: true }
// 401   : { error: "unauthorized" }
// 403   : { error: "profile_unavailable" }
// 409   : { error: "already_in_call" }
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

  const log = makeLogger("join-queue", newRequestId());
  const client = userClient(req);
  const auth = await requireUser(client);
  if (auth.response) return auth.response;

  let body: { client_id?: string } = {};
  try { body = await req.json().catch(() => ({})); } catch { body = {}; }

  const { data, error } = await client
    .rpc("mm_join_queue", { p_client_id: body.client_id ?? null })
    .single();

  if (error) {
    log.warn("rpc_failed", { code: error.code, message: error.message });
    return fromPgError(error);
  }

  log.info("joined", { user: auth.user.id });
  return ok({
    queue_id: (data as any)?.queue_id,
    expires_at: (data as any)?.expires_at,
    joined: true,
  });
});
