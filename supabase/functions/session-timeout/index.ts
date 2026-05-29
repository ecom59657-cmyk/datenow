// =============================================================================
// DateNow — session-timeout (cron / admin)
//
// Sweep périodique : élimine les entrées de file expirées, ferme les calls
// dont la fenêtre d'acceptation ou la durée max est dépassée, et coupe
// les sessions live "fantômes" (aucun heartbeat).
//
// Sécurité : cette fonction n'a PAS d'utilisateur ; elle est protégée par
// un secret partagé `MATCHING_CRON_SECRET` (header `X-Cron-Secret` ou
// `Authorization: Bearer <secret>`).
//
// Recommandé : pg_cron `* * * * * → SELECT public.mm_sweep_timeouts()`
// la fait déjà tourner depuis Postgres. Cette Edge Function est une voie
// alternative pour un scheduler externe (Supabase Cron, GitHub Actions,
// uptime-robot, etc.) avec un endpoint HTTP protégé.
//
// 200 : { queue_expired, calls_accept_timeout, calls_room_timeout, calls_ghost }
// 401 : { error: "unauthorized" }
// =============================================================================

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { handlePreflight } from "../_shared/cors.ts";
import { ok, err } from "../_shared/errors.ts";
import { serviceClient, serviceConfigured } from "../_shared/supabase.ts";
import { makeLogger, newRequestId } from "../_shared/logger.ts";

const CRON_SECRET = Deno.env.get("MATCHING_CRON_SECRET") ?? "";

function extractSecret(req: Request): string {
  const fromHeader = req.headers.get("X-Cron-Secret");
  if (fromHeader) return fromHeader.trim();
  const authz = req.headers.get("Authorization") ?? "";
  if (authz.toLowerCase().startsWith("bearer ")) return authz.slice(7).trim();
  return "";
}

serve(async (req) => {
  const pre = handlePreflight(req); if (pre) return pre;
  if (req.method !== "POST") return err(405, "method_not_allowed");

  if (!CRON_SECRET || !serviceConfigured()) {
    return err(500, "sweep_not_configured");
  }
  if (extractSecret(req) !== CRON_SECRET) {
    return err(401, "unauthorized");
  }

  const log = makeLogger("session-timeout", newRequestId());
  const client = serviceClient();
  const { data, error } = await client.rpc("mm_sweep_timeouts").single();

  if (error) {
    log.error("sweep_failed", { code: error.code, message: error.message });
    return err(500, "sweep_failed", error.message);
  }

  const row = data as any;
  const result = {
    queue_expired: row?.queue_expired ?? 0,
    calls_accept_timeout: row?.calls_accept_timeout ?? 0,
    calls_room_timeout: row?.calls_room_timeout ?? 0,
    calls_ghost: row?.calls_ghost ?? 0,
  };
  log.info("swept", result);
  return ok(result);
});
