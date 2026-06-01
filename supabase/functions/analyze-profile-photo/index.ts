// =============================================================================
// DateNow — analyze-profile-photo
//
// Server-side photo moderation pass on top of `user_photos`.
//
// Invoked once per upload by the Flutter client:
//   POST /functions/v1/analyze-profile-photo
//   Body: { photo_id?: uuid, storage_path?: string }  (either)
//
// Pipeline:
//   1. requireUser    → 401 if not signed in
//   2. Resolve photo  → 404 if not found, 403 if not owned by caller
//   3. Flip status to 'analyzing' (idempotent — skip if already terminal)
//   4. Generate a 5-min signed Storage URL → posted to Google Cloud Vision
//   5. Vision call    : SAFE_SEARCH_DETECTION + FACE_DETECTION
//   6. Decision tree  → 'approved' | 'rejected' | 'manual_review'
//   7. UPDATE user_photos + INSERT moderation_audit_log
//   8. If manual_review : INSERT moderation_queue for human review
//   9. 200 { status, reject_reason?, message }
//
// Decision rules (V1.1, dating-app calibrated):
//   REJECT (auto):
//     - SafeSearch.adult     ∈ {LIKELY, VERY_LIKELY}     → nsfw
//     - SafeSearch.violence  ∈ {LIKELY, VERY_LIKELY}     → violence
//     - SafeSearch.racy      ==  VERY_LIKELY             → suggestive_strong
//     - SafeSearch.spoof     ∈ {LIKELY, VERY_LIKELY}     → spoof_meme
//     - face count           ==  0                       → no_face
//     - face count           >   1                       → multiple_faces
//   MANUAL_REVIEW:
//     - SafeSearch.medical   ∈ {LIKELY, VERY_LIKELY}     → medical_content
//     - face detectionConfidence < 0.7 (low-quality face) → low_confidence_face
//   APPROVED otherwise.
//
//   Note (2026-06-01) : the `racy = LIKELY → manual_review` gate
//   was dropped after a TestFlight audit showed Google Vision flags
//   ordinary beach / V-neck / casual selfies as racy=LIKELY. The
//   VERY_LIKELY hard-reject is enough for genuinely sexual content;
//   the manual_review queue is now reserved for medical / low-quality
//   face cases.
//
// Required secret: GOOGLE_VISION_API_KEY (Cloud Vision API enabled
// on the linked GCP project). Set via `supabase secrets set`.
// =============================================================================

// deno-lint-ignore-file no-explicit-any
import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const SUPABASE_URL          = Deno.env.get("SUPABASE_URL")          ?? "";
const SUPABASE_ANON_KEY     = Deno.env.get("SUPABASE_ANON_KEY")     ?? "";
const SUPABASE_SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const GOOGLE_VISION_API_KEY = Deno.env.get("GOOGLE_VISION_API_KEY") ?? "";

const BUCKET                 = "profile-photos";
const SIGNED_URL_TTL_SECONDS = 5 * 60;          // 5 min — Vision call ~1 s
const VISION_ENDPOINT =
  "https://vision.googleapis.com/v1/images:annotate";

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
  `[boot] analyze-profile-photo — vision_key=${
    GOOGLE_VISION_API_KEY ? "set" : "MISSING"
  } service_role=${SUPABASE_SERVICE_ROLE ? "set" : "MISSING"}`,
);

// SafeSearch likelihood scale: VERY_UNLIKELY < UNLIKELY < POSSIBLE <
// LIKELY < VERY_LIKELY. Helper to compare.
const LIKELIHOOD_RANK: Record<string, number> = {
  UNKNOWN:        0,
  VERY_UNLIKELY:  1,
  UNLIKELY:       2,
  POSSIBLE:       3,
  LIKELY:         4,
  VERY_LIKELY:    5,
};
const atLeast = (level: string, threshold: string) =>
  (LIKELIHOOD_RANK[level] ?? 0) >= (LIKELIHOOD_RANK[threshold] ?? 99);

type Verdict =
  | { status: "approved"; reason?: never; queue?: never }
  | { status: "rejected"; reason: string; queue?: never }
  | { status: "manual_review"; reason: string; queue: true };

interface VisionDecisionInput {
  adult:    string;
  spoof:    string;
  medical:  string;
  violence: string;
  racy:     string;
  faceCount: number;
  topFaceConfidence: number;
}

function decide(input: VisionDecisionInput): Verdict {
  // ── Hard rejects (auto, no human review needed) ───────────────
  if (atLeast(input.adult,    "LIKELY"))      return { status: "rejected", reason: "nsfw" };
  if (atLeast(input.violence, "LIKELY"))      return { status: "rejected", reason: "violence" };
  if (atLeast(input.racy,     "VERY_LIKELY")) return { status: "rejected", reason: "suggestive_strong" };
  if (atLeast(input.spoof,    "LIKELY"))      return { status: "rejected", reason: "spoof_meme" };
  if (input.faceCount === 0)                  return { status: "rejected", reason: "no_face" };
  if (input.faceCount  >  1)                  return { status: "rejected", reason: "multiple_faces" };

  // ── Manual review (doubtful) ──────────────────────────────────
  //
  // The `racy === LIKELY` gate was dropped on 2026-06-01. SQL audit
  // of the four-photo TestFlight session showed a clean conforming
  // selfie classified as manual_review with :
  //   adult           = VERY_UNLIKELY
  //   racy            = LIKELY           ← the only flag
  //   face_count      = 1
  //   top_face_conf   = 0.988
  // Google Vision's `racy` detector is well known to over-fire on
  // perfectly normal dating-app shots — V-neck tops, beach selfies,
  // gym-wear, bare shoulders — so the LIKELY threshold was
  // generating false positives for the very category of photos the
  // product is designed to accept. The VERY_LIKELY hard-reject above
  // remains in place (suggestive_strong) — that catches the
  // genuinely sexual content the user spec listed as auto-refuse.
  // The medical + low-confidence-face manual_review gates are kept
  // unchanged.
  if (atLeast(input.medical, "LIKELY"))       return { status: "manual_review", reason: "medical_content",       queue: true };
  if (input.topFaceConfidence < 0.7)          return { status: "manual_review", reason: "low_confidence_face",   queue: true };

  // ── Default : approved ────────────────────────────────────────
  return { status: "approved" };
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });
  if (req.method !== "POST")     return json({ error: "method_not_allowed" }, 405);

  if (!GOOGLE_VISION_API_KEY) {
    return json({ error: "vision_api_key_missing" }, 500);
  }
  if (!SUPABASE_SERVICE_ROLE) {
    // We need the service role to UPDATE user_photos.status across
    // any RLS — the user's own client can't be trusted to flip the
    // status itself (would let a tampered client self-approve).
    return json({ error: "service_role_missing" }, 500);
  }

  // requireUser — JWT must be present + valid.
  const authHeader = req.headers.get("Authorization") ?? "";
  if (!authHeader.startsWith("Bearer ")) {
    return json({ error: "unauthorized" }, 401);
  }
  const userClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: userResult, error: userError } =
    await userClient.auth.getUser();
  if (userError || !userResult?.user) {
    return json({ error: "unauthorized" }, 401);
  }
  const callerId = userResult.user.id;

  // Body — accept either photo_id or storage_path; the client knows
  // the path immediately after upload, the photo_id requires a
  // round-trip.
  let body: any;
  try { body = await req.json(); } catch { return json({ error: "invalid_body" }, 400); }
  const photoId     = typeof body?.photo_id     === "string" ? body.photo_id     : null;
  const storagePath = typeof body?.storage_path === "string" ? body.storage_path : null;
  if (!photoId && !storagePath) {
    return json({ error: "missing_photo_id_or_path" }, 400);
  }

  // Service-role client for DB writes that must bypass RLS (status
  // flips). Reads go through the user client so ownership is implicit.
  const adminClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  // Resolve the photo row (ownership-checked via user client + RLS).
  const photoQuery = userClient
    .from("user_photos")
    .select("id, user_id, storage_path, status")
    .eq("user_id", callerId);
  const { data: photo, error: photoErr } = await (
    photoId
      ? photoQuery.eq("id", photoId).maybeSingle()
      : photoQuery.eq("storage_path", storagePath).maybeSingle()
  );
  if (photoErr) {
    console.warn(`[lookup_failed] caller=${callerId} err=${photoErr.message}`);
    return json({ error: "photo_lookup_failed" }, 500);
  }
  if (!photo) {
    return json({ error: "photo_not_found" }, 404);
  }
  if (photo.status === "approved" || photo.status === "rejected") {
    // Terminal — idempotent no-op. The Flutter client can safely
    // re-invoke without spending another Vision quota call.
    return json({
      status:  photo.status,
      message: "already_decided",
    });
  }

  // Flip to 'analyzing' so a parallel call sees in-flight + UI
  // shows the right banner.
  await adminClient
    .from("user_photos")
    .update({ status: "analyzing" })
    .eq("id", photo.id);

  // Generate a signed URL — private bucket, Vision needs HTTPS.
  const { data: signed, error: signErr } = await adminClient
    .storage
    .from(BUCKET)
    .createSignedUrl(photo.storage_path, SIGNED_URL_TTL_SECONDS);
  if (signErr || !signed?.signedUrl) {
    console.error(`[sign_failed] path=${photo.storage_path} err=${signErr?.message}`);
    return json({ error: "signed_url_failed" }, 500);
  }

  // Vision call.
  let visionResp: Response;
  try {
    visionResp = await fetch(
      `${VISION_ENDPOINT}?key=${GOOGLE_VISION_API_KEY}`,
      {
        method:  "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          requests: [{
            image:    { source: { imageUri: signed.signedUrl } },
            features: [
              { type: "SAFE_SEARCH_DETECTION" },
              { type: "FACE_DETECTION", maxResults: 5 },
            ],
          }],
        }),
      },
    );
  } catch (e) {
    console.error(`[vision_throw] photo=${photo.id} err=${e}`);
    // Don't lose the photo — flip back to pending so a cron / retry
    // can pick it up later. UI keeps showing "Photo en cours…".
    await adminClient
      .from("user_photos")
      .update({ status: "pending" })
      .eq("id", photo.id);
    return json({ error: "vision_unreachable" }, 502);
  }
  if (!visionResp.ok) {
    const text = await visionResp.text();
    console.error(`[vision_http] status=${visionResp.status} body=${text.slice(0, 200)}`);
    await adminClient
      .from("user_photos")
      .update({ status: "pending" })
      .eq("id", photo.id);
    return json({ error: "vision_failed", status: visionResp.status }, 502);
  }
  const visionJson = await visionResp.json();
  const response0 = (visionJson?.responses ?? [])[0] ?? {};
  const safeSearch = response0?.safeSearchAnnotation ?? {};
  const faceList: any[] = response0?.faceAnnotations ?? [];

  const decisionInput: VisionDecisionInput = {
    adult:    safeSearch.adult    ?? "UNKNOWN",
    spoof:    safeSearch.spoof    ?? "UNKNOWN",
    medical:  safeSearch.medical  ?? "UNKNOWN",
    violence: safeSearch.violence ?? "UNKNOWN",
    racy:     safeSearch.racy     ?? "UNKNOWN",
    faceCount:         faceList.length,
    topFaceConfidence: faceList.reduce(
      (acc: number, f: any) => Math.max(acc, f?.detectionConfidence ?? 0),
      0,
    ),
  };
  const verdict = decide(decisionInput);
  console.log(
    `[verdict] caller=${callerId} photo=${photo.id} ` +
    `status=${verdict.status} reason=${verdict.status === "approved" ? "—" : verdict.reason} ` +
    `safe=${JSON.stringify({
      adult: decisionInput.adult,    racy: decisionInput.racy,
      violence: decisionInput.violence, spoof: decisionInput.spoof,
      medical: decisionInput.medical,
    })} faces=${decisionInput.faceCount} ` +
    `topFaceConf=${decisionInput.topFaceConfidence.toFixed(3)}`,
  );

  // Persist verdict.
  const update: Record<string, unknown> = {
    status:              verdict.status,
    moderation_provider: "google_vision",
    moderation_score:    {
      safe_search: safeSearch,
      faces: faceList.map((f) => ({
        confidence: f?.detectionConfidence,
        bounding:   f?.boundingPoly,
        joy:        f?.joyLikelihood,
        anger:      f?.angerLikelihood,
        sorrow:     f?.sorrowLikelihood,
        surprise:   f?.surpriseLikelihood,
      })),
    },
    moderation_at: new Date().toISOString(),
    reject_reason: verdict.status === "approved" ? null : (verdict as any).reason ?? null,
  };
  const { error: updateErr } = await adminClient
    .from("user_photos")
    .update(update)
    .eq("id", photo.id);
  if (updateErr) {
    console.error(`[update_failed] photo=${photo.id} err=${updateErr.message}`);
    return json({ error: "db_update_failed" }, 500);
  }

  // Audit log (every verdict).
  await adminClient.from("moderation_audit_log").insert({
    photo_id: photo.id,
    user_id:  photo.user_id,
    event:    verdict.status,
    provider: "google_vision",
    payload:  update.moderation_score,
  });

  // Doubt → human review queue.
  if (verdict.status === "manual_review") {
    await adminClient.from("moderation_queue").insert({
      photo_id:   photo.id,
      user_id:    photo.user_id,
      reason:     (verdict as any).reason ?? "unknown",
      ai_payload: update.moderation_score,
    });
  }

  return json({
    status:        verdict.status,
    reject_reason: verdict.status === "approved" ? null : (verdict as any).reason ?? null,
    message:       verdict.status === "approved"
      ? "Photo validée"
      : verdict.status === "rejected"
        ? "Votre photo n'a pas pu être validée"
        : "Photo en cours de vérification",
  });
});
