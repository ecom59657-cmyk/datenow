// =============================================================================
// Réponses d'erreur normalisées.
//
// Toute Edge Function retourne :
//   - 200 { ...payload }                              (succès)
//   - 4xx/5xx { error: "code_snake_case", message? } (erreur)
// =============================================================================

import { CORS_HEADERS } from "./cors.ts";

const JSON_HEADERS = { ...CORS_HEADERS, "Content-Type": "application/json" };

/** Réponse JSON 200. */
export function ok(body: unknown): Response {
  return new Response(JSON.stringify(body), { status: 200, headers: JSON_HEADERS });
}

/** Réponse JSON d'erreur (status + code + message optionnel). */
export function err(status: number, code: string, message?: string): Response {
  return new Response(
    JSON.stringify({ error: code, message: message ?? undefined }),
    { status, headers: JSON_HEADERS },
  );
}

/**
 * Mappe un code d'erreur Postgres remonté par un RPC `mm_*` vers une
 * réponse HTTP cohérente.
 */
export function fromPgError(e: unknown): Response {
  const msg = typeof e === "object" && e && "message" in e ? String((e as any).message) : "";
  const code = typeof e === "object" && e && "code" in e ? String((e as any).code) : "";

  // Erreurs métier qu'on RAISE depuis SQL (USING ERRCODE = ...)
  if (msg.includes("unauthorized") || code === "28000") {
    return err(401, "unauthorized");
  }
  if (msg.includes("profile_unavailable") || code === "42704") {
    if (msg.includes("not_in_queue")) return err(409, "not_in_queue");
    if (msg.includes("call_not_found")) return err(404, "call_not_found");
    return err(403, "profile_unavailable");
  }
  if (msg.includes("not_a_participant") || code === "42501") {
    return err(403, "not_a_participant");
  }
  if (msg.includes("already_in_call")) return err(409, "already_in_call");
  if (msg.includes("peer_taken")) return err(409, "peer_taken");
  if (msg.includes("call_not_waiting")) return err(409, "call_not_waiting");
  if (msg.includes("accept_window_expired")) return err(410, "accept_window_expired");

  console.error("[mm] unexpected pg error:", msg, code);
  return err(500, "internal_error", msg || undefined);
}
