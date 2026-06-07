// =============================================================================
// DateNow — Apple Review login (scoped OTP bypass)
//
// Lets App Review sign in to the demo account WITHOUT a real OTP email,
// using the SAME on-screen flow (email + 6-digit code). The bypass is:
//   - scoped to a SINGLE hard-coded email (review@datenow.app), and
//   - gated by a fixed code stored as an Edge secret (documented to Apple).
// No other account is affected; the normal OTP flow is untouched.
//
// How it works: with the service role we mint a magic-link for the demo
// account, read its one-time token and verify it server-side to obtain a
// real Supabase session, which we return to the client (setSession).
//
// Required secrets (supabase secrets set ...):
//   - SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY (present)
//   - REVIEW_LOGIN_CODE  (the 6-digit code given to Apple, e.g. 480913)
//
// Deploy: supabase functions deploy review-login
// =============================================================================

// deno-lint-ignore-file no-explicit-any
import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const REVIEW_LOGIN_CODE = Deno.env.get("REVIEW_LOGIN_CODE") ?? "";

const REVIEW_EMAIL = "review@datenow.app";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  if (!SUPABASE_URL || !ANON_KEY || !SERVICE_ROLE_KEY || !REVIEW_LOGIN_CODE) {
    return json({ error: "not_configured" }, 500);
  }

  let code = "";
  try {
    const body = await req.json();
    code = String(body?.code ?? "").trim();
  } catch {
    return json({ error: "bad_request" }, 400);
  }

  // The ONLY gate: the documented fixed code. Scoped to the demo account.
  if (code !== REVIEW_LOGIN_CODE) {
    return json({ error: "invalid_code" }, 401);
  }

  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
  const anon = createClient(SUPABASE_URL, ANON_KEY);

  try {
    // Mint a one-time token for the demo account (service role).
    const { data: link, error: linkErr } = await admin.auth.admin.generateLink({
      type: "magiclink",
      email: REVIEW_EMAIL,
    });
    if (linkErr || !link?.properties?.hashed_token) {
      console.error("[review-login] generateLink failed", linkErr);
      return json({ error: "login_unavailable" }, 500);
    }

    // Exchange it for a real session (anon client).
    const { data: sess, error: verErr } = await anon.auth.verifyOtp({
      type: "email",
      token_hash: link.properties.hashed_token,
    });
    if (verErr || !sess?.session) {
      console.error("[review-login] verifyOtp failed", verErr);
      return json({ error: "login_unavailable" }, 500);
    }

    return json({
      access_token: sess.session.access_token,
      refresh_token: sess.session.refresh_token,
    });
  } catch (e) {
    console.error("[review-login] threw", e);
    return json({ error: "login_threw" }, 500);
  }
});
