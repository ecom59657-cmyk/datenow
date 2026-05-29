// =============================================================================
// DateNow — find-match
//
// Cœur du moteur. Tente d'apparier l'utilisateur avec un peer compatible
// présent en file. Race-safe (advisory lock + FOR UPDATE SKIP LOCKED dans
// la fonction SQL).
//
// Body  : { min_score?: number (10..100, défaut 40) }
// 200 succès :
//   { matched: true,  call_id, peer_id, channel_name, accept_expires_at,
//     score, relaxed }
// 200 pas de candidat :
//   { matched: false }
// 401 unauthorized
// 409 not_in_queue | already_in_call | peer_taken
// =============================================================================

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { handlePreflight } from "../_shared/cors.ts";
import { ok, err, fromPgError } from "../_shared/errors.ts";
import { requireUser } from "../_shared/auth.ts";
import { userClient } from "../_shared/supabase.ts";
import { makeLogger, newRequestId } from "../_shared/logger.ts";

const MIN_FLOOR = 10;
const MAX_SCORE = 100;
const DEFAULT_MIN = 40;

serve(async (req) => {
  const pre = handlePreflight(req); if (pre) return pre;
  if (req.method !== "POST") return err(405, "method_not_allowed");

  const log = makeLogger("find-match", newRequestId());
  const client = userClient(req);
  const auth = await requireUser(client);
  if (auth.response) return auth.response;

  // Validation min_score
  const body = await req.json().catch(() => ({} as any));
  let minScore = DEFAULT_MIN;
  if (typeof body.min_score === "number" && Number.isFinite(body.min_score)) {
    minScore = Math.max(MIN_FLOOR, Math.min(MAX_SCORE, Math.round(body.min_score)));
  }

  const { data, error } = await client
    .rpc("mm_find_match", { p_min_score: minScore })
    .single();

  if (error) {
    log.warn("rpc_failed", { code: error.code, message: error.message });
    return fromPgError(error);
  }

  const row = data as any;
  if (!row || row.matched === false) {
    log.info("no_candidate", { user: auth.user.id, min_score: minScore });
    return ok({ matched: false });
  }

  log.info("matched", {
    user: auth.user.id,
    peer: row.peer_id,
    call: row.call_id,
    score: row.score,
    relaxed: row.relaxed,
  });
  return ok({
    matched: true,
    call_id: row.call_id,
    peer_id: row.peer_id,
    channel_name: row.channel_name,
    accept_expires_at: row.accept_expires_at,
    score: row.score,
    relaxed: !!row.relaxed,
  });
});
