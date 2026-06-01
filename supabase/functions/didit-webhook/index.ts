// =============================================================================
// DateNow — didit-webhook  (Phase 2 of the Didit rollout)
//
// Receives the server-to-server callback Didit sends when a
// verification session reaches a terminal (approved/rejected/expired)
// or intermediate (in_review) state. Verifies HMAC signature, finds
// the matching `identity_verifications` row, persists the verdict,
// and — only when all gates pass — flips the user's profile row to
// verified.
//
// HTTP contract
//   POST /functions/v1/didit-webhook
//     headers : X-Didit-Signature: <hex hmac-sha256 of raw body>
//                (the function also accepts X-Signature,
//                 X-Webhook-Signature, X-Signature-256 — see TODO
//                 below — until the exact header Didit ships in
//                 sandbox is confirmed)
//     body    : Didit verdict JSON
//   200 OK   : verdict accepted (idempotent — replays return ok=true)
//   400      : malformed body
//   401      : invalid HMAC signature OR missing webhook secret
//   404      : session not found in identity_verifications
//   500      : misconfiguration / db_update_failed
//
// Decision logic (per Phase 2 brief)
//
//   approved AND age_over_18 AND face_match AND liveness
//     AND NOT age_mismatch
//                                  → UPDATE profiles SET identity_verified=true,
//                                                       age_verified=true,
//                                                       identity_provider='didit',
//                                                       identity_verified_at=now()
//                                  → iv.status = 'approved'
//
//   approved BUT age_mismatch     → iv.status = 'in_review' (admin Studio
//                                     decides ; profile NOT flipped)
//                                  → iv.reject_reason = 'age_mismatch'
//
//   rejected AND age_over_18=false → iv.status = 'rejected'
//                                  → iv.reject_reason = 'minor'
//                                  → profile NOT flipped (forever locked)
//
//   rejected (other reasons)       → iv.status = 'rejected'
//                                  → iv.reject_reason = …mapped reason
//
//   expired                        → iv.status = 'expired'
//
//   in_review (Didit still
//    processing)                   → iv.status = 'in_review'
//
// Idempotency
//   Didit retries failed webhooks. If our row is already in a
//   terminal state (approved / rejected) the second delivery is a
//   no-op — the verdict cannot be downgraded.
//
// Privacy
//   `raw_payload` is overwritten each time so the latest Didit JSON
//   is always on file (audit + GDPR DPIA). No PII surfaces in
//   structured columns beyond the boolean age_over_18 and the int
//   age_extracted — names, document numbers, photo URLs all stay
//   inside the JSONB, RLS-protected, owner-readable only.
//
// Secrets required (set with `supabase secrets set …`):
//   DIDIT_WEBHOOK_SECRET       — shared with Didit dashboard, used
//                                for HMAC-SHA256 signature verification
//   SUPABASE_SERVICE_ROLE_KEY  — bypasses RLS for the UPDATEs on
//                                identity_verifications + profiles
// =============================================================================

// deno-lint-ignore-file no-explicit-any
import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const SUPABASE_URL          = Deno.env.get("SUPABASE_URL")              ?? "";
const SUPABASE_SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const WEBHOOK_SECRET        = Deno.env.get("DIDIT_WEBHOOK_SECRET")      ?? "";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin":   "*",
  "Access-Control-Allow-Headers":  "content-type, x-didit-signature, x-signature, x-signature-256, x-webhook-signature",
  "Access-Control-Allow-Methods":  "POST, OPTIONS",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

console.log(
  `[Didit][INFO] boot didit-webhook — secret=${
    WEBHOOK_SECRET ? "set" : "MISSING"
  } service_role=${SUPABASE_SERVICE_ROLE ? "set" : "MISSING"}`,
);

// ── HMAC-SHA256 signature verification ─────────────────────────
//
// Constant-time hex compare. The function tries multiple common
// header names because the exact header Didit emits in sandbox is
// not documented in the Phase 2 brief — once the first real webhook
// lands, the [Didit][WARN] log line below will show which header
// was actually present and we narrow the list.
async function verifySignature(rawBody: string, sig: string): Promise<boolean> {
  if (!sig || !WEBHOOK_SECRET) return false;
  // Some providers prefix with "sha256=" — strip it.
  let provided = sig.trim();
  if (provided.startsWith("sha256=")) provided = provided.slice(7);
  provided = provided.toLowerCase();

  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    enc.encode(WEBHOOK_SECRET),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sigBuf = await crypto.subtle.sign("HMAC", key, enc.encode(rawBody));
  const expected = Array.from(new Uint8Array(sigBuf))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");

  if (provided.length !== expected.length) return false;
  let diff = 0;
  for (let i = 0; i < provided.length; i++) {
    diff |= provided.charCodeAt(i) ^ expected.charCodeAt(i);
  }
  return diff === 0;
}

// ── Map Didit raw status → our internal enum value ─────────────
//
// TODO(didit-webhook) : confirm exact strings emitted by Didit
// sandbox in the first real webhook delivery. The mapping below
// covers the V3 create-session status ("Not Started") + best-guess
// terminal labels based on common KYC provider vocabulary. Unknown
// values fall back to `in_review` (safer than letting through as
// approved or marking as rejected without evidence).
function mapDiditStatus(raw: string | undefined | null): string {
  if (!raw) return "in_review";
  const v = raw.trim().toLowerCase();
  switch (v) {
    case "not started":
    case "pending":
      return "pending";
    case "in progress":
    case "processing":
    case "in review":
    case "in_review":
      return "in_review";
    case "approved":
    case "accepted":
    case "success":
      return "approved";
    case "declined":
    case "rejected":
    case "failed":
      return "rejected";
    case "expired":
    case "abandoned":
    case "timeout":
      return "expired";
    default:
      console.warn(`[Didit][WARN] unknown raw status "${raw}" — defaulting to in_review`);
      return "in_review";
  }
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });
  if (req.method !== "POST")    return json({ error: "method_not_allowed" }, 405);

  if (!WEBHOOK_SECRET)        return json({ error: "webhook_secret_missing" }, 500);
  if (!SUPABASE_SERVICE_ROLE) return json({ error: "service_role_missing" },   500);

  // Read raw body BEFORE any parsing — HMAC must be computed on
  // the exact bytes Didit sent, not on a re-stringified JSON.
  const rawBody = await req.text();

  // ── 1. HMAC signature verification ───────────────────────────
  const presentedSig =
    req.headers.get("X-Didit-Signature") ??
    req.headers.get("X-Signature") ??
    req.headers.get("X-Signature-256") ??
    req.headers.get("X-Webhook-Signature") ??
    "";

  // TODO(didit-webhook) : when the first sandbox webhook lands,
  // log the keys of req.headers to confirm which header Didit
  // actually emits, then narrow the lookup list to just that name.
  if (!await verifySignature(rawBody, presentedSig)) {
    console.warn(
      `[Didit][WARN] invalid HMAC signature — presented=${
        presentedSig ? presentedSig.slice(0, 16) + "…" : "(none)"
      } body_len=${rawBody.length}`,
    );
    return json({ error: "invalid_signature" }, 401);
  }

  // ── 2. Parse body ────────────────────────────────────────────
  let payload: any;
  try {
    payload = JSON.parse(rawBody);
  } catch {
    console.error(`[Didit][ERROR] invalid JSON body length=${rawBody.length}`);
    return json({ error: "invalid_body" }, 400);
  }

  // TODO(didit-webhook) : exact field paths to confirm against the
  // first real sandbox webhook. The defaults below follow common
  // KYC provider conventions (decision.{id_verification,face_match,
  // liveness,age_estimation}.*) and the V3 create-session response
  // shape (top-level session_id + vendor_data + status). If the
  // real payload uses different keys (e.g. `decisions` plural,
  // `face_match_result` vs `face_match.status`, etc.) flag them and
  // we patch the parser — no schema change required, JSONB handles it.
  const sessionId  = payload?.session_id    as string | undefined;
  const vendorData = payload?.vendor_data   as string | undefined;
  const rawStatus  = payload?.status        as string | undefined;
  const decision   = payload?.decision      ?? payload?.decisions ?? {};

  if (!sessionId && !vendorData) {
    console.error(
      `[Didit][ERROR] webhook missing both session_id and vendor_data ` +
      `payload_preview=${rawBody.slice(0, 200)}`,
    );
    return json({ error: "missing_session_id" }, 400);
  }

  // ── 3. Locate the audit row ──────────────────────────────────
  const adminClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  let row: any = null;
  if (sessionId) {
    const { data } = await adminClient
      .from("identity_verifications")
      .select("id, user_id, status, age_claimed")
      .eq("external_session_id", sessionId)
      .maybeSingle();
    row = data;
  }
  if (!row && vendorData) {
    // Fallback : if Didit's webhook does NOT carry session_id for
    // some reason, find the most recent open verification row for
    // the user (vendor_data == user_id by our convention in
    // didit-create-session).
    const { data } = await adminClient
      .from("identity_verifications")
      .select("id, user_id, status, age_claimed")
      .eq("user_id", vendorData)
      .in("status", ["pending", "in_review"])
      .order("created_at", { ascending: false })
      .limit(1);
    row = data?.[0];
  }

  if (!row) {
    console.warn(
      `[Didit][WARN] webhook for unknown session ` +
      `session_id=${sessionId ?? "—"} vendor_data=${vendorData ?? "—"}`,
    );
    return json({ error: "session_not_found" }, 404);
  }

  // ── 4. Idempotency check ─────────────────────────────────────
  if (row.status === "approved" || row.status === "rejected") {
    console.log(
      `[Didit][INFO] webhook replay session=${sessionId} ` +
      `existing_status=${row.status} — idempotent no-op`,
    );
    return json({ ok: true, idempotent: true, status: row.status });
  }

  // ── 5. Extract verdict details ───────────────────────────────
  const idV         = (decision as any)?.id_verification ?? (decision as any)?.document   ?? {};
  const docData     = idV?.document_data ?? idV?.data ?? {};
  const faceMatch   = (decision as any)?.face_match   ?? {};
  const liveness    = (decision as any)?.liveness     ?? {};
  const ageEst      = (decision as any)?.age_estimation ?? (decision as any)?.age ?? {};

  // age_extracted : try multiple paths because Didit V3 sandbox
  // exact structure is TBD.
  const ageExtractedRaw =
    ageEst?.age ??
    ageEst?.value ??
    idV?.age ??
    docData?.age ??
    null;
  const ageExtracted: number | null =
    typeof ageExtractedRaw === "number" ? Math.trunc(ageExtractedRaw) : null;

  // age_over_18 : prefer explicit boolean from Didit, fallback to
  // computed from age_extracted, fallback to null (unknown).
  const ageOver18Raw =
    typeof ageEst?.is_adult === "boolean" ? ageEst.is_adult :
    typeof ageEst?.over_18  === "boolean" ? ageEst.over_18  :
    ageExtracted !== null ? ageExtracted >= 18 :
    null;
  const ageOver18: boolean | null = ageOver18Raw;

  const faceMatchStatus =
    (typeof faceMatch?.status === "string" ? faceMatch.status : null)
      ?.toLowerCase() ?? null;
  const livenessStatus =
    (typeof liveness?.status === "string" ? liveness.status : null)
      ?.toLowerCase() ?? null;

  const ourStatus = mapDiditStatus(rawStatus);

  // Derive reject_reason for the rejected branch.
  let rejectReason: string | null = null;
  if (ourStatus === "rejected") {
    if (ageOver18 === false) {
      rejectReason = "minor";
    } else if (faceMatchStatus && faceMatchStatus !== "match" && faceMatchStatus !== "success" && faceMatchStatus !== "passed") {
      rejectReason = "face_mismatch";
    } else if (livenessStatus && livenessStatus !== "passed" && livenessStatus !== "success" && livenessStatus !== "live") {
      rejectReason = "liveness_failed";
    } else if (
      typeof idV?.status === "string" &&
      ["rejected", "declined", "invalid", "failed"].includes(idV.status.toLowerCase())
    ) {
      rejectReason = "document_invalid";
    } else {
      rejectReason = "rejected_other";
    }
  } else if (ourStatus === "expired") {
    rejectReason = "expired";
  }

  // ── 6. UPDATE identity_verifications ─────────────────────────
  const ivUpdate: Record<string, unknown> = {
    status:        ourStatus,
    raw_payload:   payload,
    decided_at:    new Date().toISOString(),
    submitted_at:  row.submitted_at ?? new Date().toISOString(),
  };
  if (ageOver18    !== null) ivUpdate.age_over_18   = ageOver18;
  if (ageExtracted !== null) ivUpdate.age_extracted = ageExtracted;
  if (rejectReason !== null) ivUpdate.reject_reason = rejectReason;

  const { error: ivErr } = await adminClient
    .from("identity_verifications")
    .update(ivUpdate)
    .eq("id", row.id);

  if (ivErr) {
    console.error(
      `[Didit][ERROR] iv update failed user=${row.user_id} ` +
      `session=${sessionId} err=${ivErr.message}`,
    );
    return json({ error: "db_update_failed" }, 500);
  }

  console.log(
    `[Didit][INFO] iv updated user=${row.user_id} session=${sessionId} ` +
    `our_status=${ourStatus} raw_status=${rawStatus ?? "—"} ` +
    `age_extracted=${ageExtracted ?? "—"} age_over_18=${ageOver18 ?? "—"} ` +
    `face=${faceMatchStatus ?? "—"} liveness=${livenessStatus ?? "—"} ` +
    `reject_reason=${rejectReason ?? "—"}`,
  );

  // ── 7. Profile flip (only on a real approval) ────────────────
  //
  // Conditions ALL required :
  //   - mapped status == 'approved'
  //   - Didit says age_over_18 is true
  //   - face_match is success-shaped (or absent — defensive default)
  //   - liveness is passed (or absent)
  //   - age_mismatch (STORED generated column) is false — i.e. the
  //     age user typed at onboarding matches Didit's extracted age
  //     within 1 year tolerance
  if (
    ourStatus      === "approved"  &&
    ageOver18      === true        &&
    (faceMatchStatus === null || ["match", "success", "passed"].includes(faceMatchStatus)) &&
    (livenessStatus  === null || ["passed", "success", "live"].includes(livenessStatus))
  ) {
    // Re-read the row to see age_mismatch (STORED computed column,
    // refreshed on the UPDATE above).
    const { data: refreshed } = await adminClient
      .from("identity_verifications")
      .select("age_mismatch, age_claimed, age_extracted")
      .eq("id", row.id)
      .maybeSingle();

    if (refreshed?.age_mismatch === true) {
      console.warn(
        `[Didit][WARN] age mismatch user=${row.user_id} ` +
        `claimed=${refreshed.age_claimed} extracted=${refreshed.age_extracted} ` +
        `→ flipping iv to in_review (manual review)`,
      );
      await adminClient
        .from("identity_verifications")
        .update({
          status:        "in_review",
          reject_reason: "age_mismatch",
        })
        .eq("id", row.id);
      return json({ ok: true, status: "in_review", reason: "age_mismatch" });
    }

    // Real approval — flip the profile.
    const { error: profileErr } = await adminClient
      .from("profiles")
      .update({
        identity_verified:    true,
        age_verified:         true,
        identity_provider:    "didit",
        identity_verified_at: new Date().toISOString(),
      })
      .eq("id", row.user_id);

    if (profileErr) {
      console.error(
        `[Didit][ERROR] profile flip failed user=${row.user_id} ` +
        `err=${profileErr.message}`,
      );
      return json({ error: "profile_flip_failed" }, 500);
    }

    console.log(`[Didit][INFO] profile flipped to verified user=${row.user_id}`);
    return json({ ok: true, status: "approved", profile_flipped: true });
  }

  // Non-approved verdict OR a gate failed (e.g. approved but
  // face_match=no_match). The iv row already carries the right
  // status; profile NOT flipped.
  return json({ ok: true, status: ourStatus, reason: rejectReason });
});
