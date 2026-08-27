// =============================================================================
// DateNow — admob-ssv
//
// Google calls this when a user has genuinely finished a rewarded video. It
// is the only path that can add a date to someone's day: since
// 20260827110000 the client has no grant of its own, so closing the video
// early produces no callback and therefore no reward. "Watch it or don't get
// it" stops being a promise the app makes to itself.
//
// HTTP contract
//   GET /functions/v1/admob-ssv?ad_network=…&…&signature=…&key_id=…
//     200 {ok:true, granted:bool, …}  accepted — stop retrying
//     401 {error:"bad_signature"}     not from Google, or tampered with
//     400 {error:"malformed"}         not a callback shape
//     503 {error:…}                   our fault, please retry
//
// Status codes are the whole conversation with Google: anything non-2xx is
// retried, so a refusal we mean must be a 200 and only a transient failure
// may be a 5xx. A "daily limit reached" answered with 500 would be redelivered
// for hours.
//
// ⚠ DEPLOY WITH JWT VERIFICATION OFF:
//     supabase functions deploy admob-ssv --no-verify-jwt
//   Google does not carry a Supabase JWT. The signature is the authentication
//   — that is what makes it safe to leave open.
//
// Then paste the function URL into AdMob → Ad units → the rewarded unit →
// Server-side verification. See docs/ADMOB_SSV.md.
// =============================================================================

import { serviceClient, serviceConfigured } from "../_shared/supabase.ts";
import { makeLogger, newRequestId } from "../_shared/logger.ts";
import { err, ok } from "../_shared/errors.ts";
import { CORS_HEADERS } from "../_shared/cors.ts";
import { isFresh, parseCallback, verifySsvSignature } from "./verify.ts";

const KEY_SERVER = "https://gstatic.com/admob/reward/verifier-keys.json";

// Google rotates these on a variable schedule and asks that they not be held
// for more than 24 hours. An hour keeps a rotation from costing us a batch of
// rewards while still sparing the key server on every callback.
const KEY_TTL_MS = 60 * 60 * 1000;

interface VerifierKey {
  keyId: number | string;
  pem: string;
  base64?: string;
}

let keyCache: { at: number; keys: Map<string, string> } | null = null;

async function verifierKey(keyId: string, log: ReturnType<typeof makeLogger>) {
  const fresh = keyCache && Date.now() - keyCache.at < KEY_TTL_MS;
  if (fresh && keyCache!.keys.has(keyId)) return keyCache!.keys.get(keyId)!;

  // A key id we have never seen is the normal shape of a rotation, so refetch
  // even when the cache has not expired.
  const res = await fetch(KEY_SERVER);
  if (!res.ok) throw new Error(`key_server_${res.status}`);
  const body = await res.json() as { keys: VerifierKey[] };

  const keys = new Map<string, string>();
  for (const k of body.keys ?? []) keys.set(String(k.keyId), k.pem);
  keyCache = { at: Date.now(), keys };
  log.info("verifier keys refreshed", { count: keys.size });

  return keys.get(keyId);
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: CORS_HEADERS });
  }
  const requestId = newRequestId();
  const log = makeLogger("admob-ssv", requestId);

  const callback = parseCallback(req.url);
  if (!callback) {
    log.warn("not a callback shape");
    return err(400, "malformed");
  }

  const { signedContent, signature, keyId, params } = callback;
  const transactionId = params.get("transaction_id") ?? "";
  const userId = params.get("user_id") ?? "";

  let pem: string | undefined;
  try {
    pem = await verifierKey(keyId, log);
  } catch (e) {
    // The key server being unreachable is our problem, not Google's. Ask for
    // a retry rather than dropping a reward the user has earned.
    log.error("key fetch failed", { message: String(e) });
    return err(503, "key_server_unreachable");
  }
  if (!pem) {
    log.warn("unknown key id", { keyId });
    return err(401, "bad_signature");
  }

  if (!await verifySsvSignature(signedContent, signature, pem)) {
    log.warn("signature rejected", { keyId, transactionId });
    return err(401, "bad_signature");
  }

  // Only now is anything in the query string worth reading.
  const ts = Number(params.get("timestamp"));
  if (!isFresh(ts, Date.now())) {
    // Signed, but old: someone kept a URL. The unique transaction id would
    // catch a replay of one we already paid; this catches the rest.
    log.warn("stale callback", { ts, transactionId });
    return ok({ ok: true, granted: false, reason: "stale" });
  }

  if (!userId) {
    // The app failed to set ServerSideVerificationOptions.userId, so there is
    // nobody to pay. 200: retrying will not conjure one.
    log.warn("no user_id on a valid callback", { transactionId });
    return ok({ ok: true, granted: false, reason: "no_user_id" });
  }

  if (!serviceConfigured()) {
    log.error("service role key missing");
    return err(503, "not_configured");
  }

  const { data, error } = await serviceClient()
    .rpc("grant_quota_bonus_ssv", {
      p_user_id: userId,
      p_transaction_id: transactionId,
    });

  if (error) {
    log.error("grant failed", { code: error.code, message: error.message });
    return err(503, "grant_failed");
  }

  const granted = (data as Record<string, unknown>)?.granted === true;
  log.info("callback settled", { userId, transactionId, granted, data });
  return ok({ ok: true, ...(data as Record<string, unknown>) });
});
