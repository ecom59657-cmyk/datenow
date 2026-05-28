// =============================================================================
// Auth utilitaire : récupère l'utilisateur depuis le Bearer token.
// =============================================================================

import type { SupabaseClient, User } from "https://esm.sh/@supabase/supabase-js@2.45.4";
import { err } from "./errors.ts";

/**
 * Récupère l'utilisateur à partir du client utilisateur. Retourne
 * `{ user }` en cas de succès ou `{ response }` (401) à renvoyer
 * directement au client en cas d'échec.
 */
export async function requireUser(
  client: SupabaseClient,
): Promise<{ user: User; response?: undefined } | { user?: undefined; response: Response }> {
  const { data, error } = await client.auth.getUser();
  if (error || !data?.user) {
    return { response: err(401, "unauthorized") };
  }
  return { user: data.user };
}
