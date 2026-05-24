// =============================================================================
// DateNow — Account deletion
//
// Apple App Store requires an in-app path to delete the user's account.
// This Edge Function:
//   1. Authenticates the caller with their own JWT.
//   2. Invokes the `delete_my_account()` RPC under the user's session so
//      every per-table delete cascade is RLS-audited.
//   3. Deletes the matching `auth.users` row with the service-role key
//      so the email can be reused.
//
// Required secrets (set with `supabase secrets set`):
//   - SUPABASE_URL                — already present
//   - SUPABASE_ANON_KEY           — already present
//   - SUPABASE_SERVICE_ROLE_KEY   — REQUIRED, never expose anywhere else
//
// Deploy with:
//   supabase functions deploy delete-account
// =============================================================================

// deno-lint-ignore-file no-explicit-any
import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

console.log(
  `[boot] SUPABASE_URL=${SUPABASE_URL ? "set" : "MISSING"} ` +
    `SERVICE_ROLE_KEY=${SERVICE_ROLE_KEY ? "set" : "MISSING"}`,
);

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: CORS_HEADERS });
  }
  if (req.method !== "POST") {
    return json({ error: "method_not_allowed" }, 405);
  }
  if (!SUPABASE_URL || !SUPABASE_ANON_KEY || !SERVICE_ROLE_KEY) {
    return json({ error: "delete_not_configured" }, 500);
  }

  const authHeader = req.headers.get("Authorization") ?? "";
  if (!authHeader.startsWith("Bearer ")) {
    return json({ error: "unauthorized" }, 401);
  }

  // 1. Identify the caller from the JWT.
  const userClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
  });

  const { data: userResult, error: userError } =
    await userClient.auth.getUser();
  if (userError || !userResult?.user) {
    return json({ error: "unauthorized" }, 401);
  }
  const userId = userResult.user.id;

  // 2. Run the RLS-safe data wipe as the user.
  try {
    const { error: rpcErr } = await userClient.rpc("delete_my_account");
    if (rpcErr) {
      console.error(`[wipe-fail] user=${userId}`, rpcErr);
      return json(
        { error: "wipe_failed", detail: rpcErr.message },
        500,
      );
    }
  } catch (e) {
    console.error(`[wipe-throw] user=${userId}`, e);
    return json({ error: "wipe_threw" }, 500);
  }

  // 3. Delete the auth.users row with the service role so the email
  //    can be re-registered. The user has no profile row anymore so
  //    even if this step fails, no DateNow data remains.
  const adminClient = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
  try {
    const { error: authErr } = await adminClient.auth.admin.deleteUser(userId);
    if (authErr) {
      // Surface the failure so the client can surface a soft warning,
      // but the data is already gone — this is recoverable.
      console.error(`[auth-delete-fail] user=${userId}`, authErr);
      return json(
        { ok: true, auth_deleted: false, warning: authErr.message },
        200,
      );
    }
  } catch (e) {
    console.error(`[auth-delete-throw] user=${userId}`, e);
    return json({ ok: true, auth_deleted: false }, 200);
  }

  console.log(`[deleted] user=${userId}`);
  return json({ ok: true, auth_deleted: true });
});
