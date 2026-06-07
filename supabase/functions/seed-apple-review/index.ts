// =============================================================================
// DateNow — Apple Review seeding (one-shot setup)
//
// Creates (idempotently) the demo auth users and seeds their data so App
// Review can test the app with REAL screens:
//   - review@datenow.app  (the reviewer demo account)
//   - anna.demo@datenow.app (the Anna demo profile — never logs in)
// then calls the SQL RPC `seed_apple_review(review_id, anna_id)`.
//
// Protected by a shared secret header so it can't be triggered by anyone.
//
// Required secrets (supabase secrets set ...):
//   - SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY  (already present)
//   - REVIEW_SEED_SECRET                        (any long random string)
//
// Run once:
//   supabase functions deploy seed-apple-review
//   curl -X POST "https://<project>.functions.supabase.co/seed-apple-review" \
//        -H "x-seed-secret: <REVIEW_SEED_SECRET>"
// =============================================================================

// deno-lint-ignore-file no-explicit-any
import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const SEED_SECRET = Deno.env.get("REVIEW_SEED_SECRET") ?? "";

const REVIEW_EMAIL = "review@datenow.app";
const ANNA_EMAIL = "anna.demo@datenow.app";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-seed-secret, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

async function ensureUser(admin: any, email: string): Promise<string> {
  const created = await admin.auth.admin.createUser({
    email,
    email_confirm: true,
    user_metadata: { demo: true },
  });
  if (!created.error && created.data?.user) return created.data.user.id;

  // Already exists → resolve the id via paginated listUsers.
  for (let page = 1; page <= 50; page++) {
    const { data, error } = await admin.auth.admin.listUsers({ page, perPage: 200 });
    if (error) throw error;
    const found = data.users.find(
      (u: any) => (u.email ?? "").toLowerCase() === email.toLowerCase(),
    );
    if (found) return found.id;
    if (data.users.length < 200) break;
  }
  throw new Error(`could not resolve user ${email}`);
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  if (!SUPABASE_URL || !SERVICE_ROLE_KEY) return json({ error: "not_configured" }, 500);
  if (!SEED_SECRET || req.headers.get("x-seed-secret") !== SEED_SECRET) {
    return json({ error: "unauthorized" }, 401);
  }

  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
  try {
    const reviewId = await ensureUser(admin, REVIEW_EMAIL);
    const annaId = await ensureUser(admin, ANNA_EMAIL);

    const { error: rpcErr } = await admin.rpc("seed_apple_review", {
      p_review: reviewId,
      p_anna: annaId,
    });
    if (rpcErr) {
      console.error("[seed-fail]", rpcErr);
      return json({ error: "seed_failed", detail: rpcErr.message }, 500);
    }

    console.log(`[seeded] review=${reviewId} anna=${annaId}`);
    return json({ ok: true, review_id: reviewId, anna_id: annaId });
  } catch (e) {
    console.error("[seed-throw]", e);
    return json({ error: "seed_threw", detail: String(e) }, 500);
  }
});
