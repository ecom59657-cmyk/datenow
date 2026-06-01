// =============================================================================
// DateNow — didit-create-session  (Phase 2 + Phase 6 of the Didit rollout)
//
// Called by the Flutter screen when the user taps "Vérifier mon
// identité". Hits Didit V3 to spin up a verification session, persists
// the audit row, and returns the session_token the Flutter app passes
// to the native didit_sdk plugin.
//
// HTTP contract
//   POST /functions/v1/didit-create-session
//     headers : Authorization: Bearer <supabase_user_jwt>
//     body    : (none)
//
//   200 OK   : { session_id, session_token, session_url, expires_at, status }
//              status = "pending"  fresh session
//              status = "reused"   existing open session
//              status = "approved" already verified (no-op)
//   401      : not signed in
//   500      : misconfiguration (missing secrets) or db_insert_failed
//   502      : Didit unreachable / returned non-2xx / malformed
//
// Idempotency
//   Looks up any existing `identity_verifications` row in {pending,
//   in_review, approved}. If one exists, returns its existing
//   token / status — never spins up a duplicate Didit session.
//
// Phase 6 security note — session_token exposure
//   Earlier Phase 2 kept the `session_token` server-side only. The
//   migration to the native didit_sdk plugin (Phase 6) requires the
//   client to receive the token because `DiditSdk.startVerification`
//   takes it as its only argument. The token :
//     * is bound to ONE user's ONE verification session
//     * expires in ~30 min (no longer than SESSION_TTL_MS)
//     * cannot be used to create other sessions / read other users
//     * cannot be used to read or rotate the API key
//   Returning it to the authenticated caller is the documented
//   integration pattern, so the trade-off is acceptable. The
//   `session_url` is still surfaced as a fallback (for debug builds
//   or for future re-introduction of the hosted-URL path).
//
// Secrets required (set with `supabase secrets set …`):
//   DIDIT_API_KEY              — x-api-key header on Didit V3 calls
//   SUPABASE_SERVICE_ROLE_KEY  — auto-provided, bypasses RLS for the
//                                INSERT into identity_verifications
// =============================================================================

// deno-lint-ignore-file no-explicit-any
import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const SUPABASE_URL          = Deno.env.get("SUPABASE_URL")              ?? "";
const SUPABASE_ANON_KEY     = Deno.env.get("SUPABASE_ANON_KEY")         ?? "";
const SUPABASE_SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const DIDIT_API_KEY         = Deno.env.get("DIDIT_API_KEY")             ?? "";

// Didit V3 — confirmed by sandbox response in the Phase 2 brief.
const DIDIT_CREATE_SESSION_URL = "https://verification.didit.me/v3/session/";
const WORKFLOW_ID    = "c5f47435-a6be-4fc5-a655-8bfb99894365";
const CALLBACK_URL   = "datenow://didit/return";

// Sessions Didit are documented to expire ~30 minutes after creation
// when the user does not finish. The V3 response payload we have on
// file does NOT include an explicit `expires_at`, so we compute one
// locally and surface it to the client — the Flutter UI uses it to
// show a "session expirée" message after that window and to gate the
// retry button.
const SESSION_TTL_MS = 30 * 60 * 1000;

const CORS_HEADERS = {
  "Access-Control-Allow-Origin":   "*",
  "Access-Control-Allow-Headers":  "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods":  "POST, OPTIONS",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

console.log(
  `[Didit][INFO] boot didit-create-session — api_key=${
    DIDIT_API_KEY ? `set (${DIDIT_API_KEY.length} chars)` : "MISSING"
  } service_role=${SUPABASE_SERVICE_ROLE ? "set" : "MISSING"} ` +
  `endpoint=${DIDIT_CREATE_SESSION_URL} workflow=${WORKFLOW_ID.slice(0, 8)}…`,
);

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });
  if (req.method !== "POST")    return json({ error: "method_not_allowed" }, 405);

  if (!DIDIT_API_KEY)         return json({ error: "didit_api_key_missing" },        500);
  if (!SUPABASE_SERVICE_ROLE) return json({ error: "service_role_missing" },         500);

  // ── 1. requireUser ────────────────────────────────────────────
  const authHeader = req.headers.get("Authorization") ?? "";
  if (!authHeader.startsWith("Bearer ")) return json({ error: "unauthorized" }, 401);

  const userClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: userResult, error: userError } =
    await userClient.auth.getUser();
  if (userError || !userResult?.user) {
    return json({ error: "unauthorized" }, 401);
  }
  const userId = userResult.user.id;

  // ── 2. Service-role client for the writes that must bypass RLS ─
  const adminClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  // ── 3. Idempotency : reuse an existing open or approved session ─
  const { data: existing } = await adminClient
    .from("identity_verifications")
    .select("id, external_session_id, status, raw_payload")
    .eq("user_id", userId)
    .in("status", ["pending", "in_review", "approved"])
    .order("created_at", { ascending: false })
    .limit(1);

  if (existing && existing.length > 0) {
    const row = existing[0] as any;
    if (row.status === "approved") {
      console.log(`[Didit][INFO] already verified user=${userId} — no-op`);
      return json({ status: "approved", already_verified: true });
    }
    const existingUrl   = row?.raw_payload?.url            as string | undefined;
    const existingToken = row?.raw_payload?.session_token  as string | undefined;
    if (existingUrl && existingToken) {
      console.log(
        `[Didit][INFO] reusing open session user=${userId} ` +
        `session=${row.external_session_id} status=${row.status}`,
      );
      return json({
        session_id:    row.external_session_id,
        session_token: existingToken,
        session_url:   existingUrl,
        status:        "reused",
        expires_at:    new Date(Date.now() + SESSION_TTL_MS).toISOString(),
      });
    }
    // existing open row but URL missing — fall through and create a
    // fresh session. We do NOT delete the orphan row; the next webhook
    // for that session_id will find it via vendor_data fallback.
  }

  // ── 4. age_claimed from profiles.birth_date ───────────────────
  // We store the age the user typed at onboarding so the eventual
  // webhook can compare it to Didit's extracted DOB (age_mismatch
  // is a STORED generated column on identity_verifications).
  const { data: profile } = await adminClient
    .from("profiles")
    .select("birth_date")
    .eq("id", userId)
    .maybeSingle();

  let ageClaimed: number | null = null;
  if (profile?.birth_date) {
    const birth = new Date(profile.birth_date as string);
    if (!isNaN(birth.getTime())) {
      const now = new Date();
      ageClaimed = now.getFullYear() - birth.getFullYear();
      const m = now.getMonth() - birth.getMonth();
      if (m < 0 || (m === 0 && now.getDate() < birth.getDate())) ageClaimed--;
    }
  }

  // ── 5. Call Didit V3 ──────────────────────────────────────────
  let diditResp: Response;
  try {
    diditResp = await fetch(DIDIT_CREATE_SESSION_URL, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        // V3 confirmed : auth via `x-api-key`, not Bearer.
        "x-api-key":    DIDIT_API_KEY,
      },
      body: JSON.stringify({
        workflow_id:     WORKFLOW_ID,
        vendor_data:     userId,
        callback:        CALLBACK_URL,
        callback_method: "both",
        metadata: {
          source:      "datenow",
          environment: "sandbox",
        },
      }),
    });
  } catch (e) {
    console.error(`[Didit][ERROR] fetch threw user=${userId} err=${e}`);
    return json({ error: "didit_unreachable" }, 502);
  }

  if (!diditResp.ok) {
    const text = await diditResp.text();
    console.error(
      `[Didit][ERROR] create session user=${userId} ` +
      `status=${diditResp.status} body=${text.slice(0, 300)}`,
    );
    return json({ error: "didit_failed", upstream: diditResp.status }, 502);
  }

  let diditData: any;
  try {
    diditData = await diditResp.json();
  } catch (e) {
    console.error(`[Didit][ERROR] response not JSON user=${userId}`);
    return json({ error: "didit_invalid_response" }, 502);
  }
  // V3 response confirmed in the brief :
  //   session_id, session_number, session_token, url, vendor_data,
  //   metadata, status ("Not Started"), callback, workflow_id,
  //   workflow_version
  const sessionId    = diditData?.session_id    as string | undefined;
  const sessionToken = diditData?.session_token as string | undefined;
  const sessionUrl   = diditData?.url           as string | undefined;
  const rawStatus    = diditData?.status        as string | undefined;

  // session_token is the only mandatory field for the native SDK
  // (Phase 6) ; session_url is the fallback for the hosted flow.
  // session_id is needed to correlate the eventual webhook.
  if (!sessionId || !sessionToken || !sessionUrl) {
    console.error(
      `[Didit][ERROR] invalid Didit response user=${userId} ` +
      `payload=${JSON.stringify(diditData).slice(0, 300)}`,
    );
    return json({ error: "didit_invalid_response" }, 502);
  }

  console.log(
    `[Didit][INFO] session created user=${userId} ` +
    `session=${sessionId} raw_status=${rawStatus ?? "—"} ` +
    `age_claimed=${ageClaimed ?? "—"}`,
  );

  // ── 6. Persist audit row ─────────────────────────────────────
  // raw_payload stores the full V3 response (incl. session_token)
  // — never surfaced through any client-facing API. RLS keeps it
  // owner-readable but the column is not selected anywhere outside
  // this Edge Function.
  const { error: insertErr } = await adminClient
    .from("identity_verifications")
    .insert({
      user_id:             userId,
      provider:            "didit",
      external_session_id: sessionId,
      status:              "pending",
      age_claimed:         ageClaimed,
      raw_payload:         diditData,
    });

  if (insertErr) {
    console.error(`[Didit][ERROR] insert iv user=${userId} err=${insertErr.message}`);
    return json({ error: "db_insert_failed" }, 500);
  }

  // ── 7. Response to client ────────────────────────────────────
  // session_token is the only field the native SDK needs to start
  // the verification (Phase 6). session_url + session_id are
  // returned for fallback / debug / analytics.
  return json({
    session_id:    sessionId,
    session_token: sessionToken,
    session_url:   sessionUrl,
    expires_at:    new Date(Date.now() + SESSION_TTL_MS).toISOString(),
    status:        "pending",
  });
});
