// =============================================================================
// DateNow — message-notification Edge Function (APNs HTTP/2)
//
// Triggered by a Supabase Database Webhook on INSERT into
// `public.messages`. Looks up the recipient's device_tokens row(s) and
// sends a content-minimal push to each via Apple's HTTP/2 APNs endpoint.
//
// Privacy: the push body carries ONLY the sender's first name. The
// message text is never included. The recipient's app fetches the
// real conversation via Supabase Realtime / mark-as-read when the user
// taps the notification.
//
// Required Supabase secrets (`supabase secrets set ...`):
//   APNS_KEY            — full contents of AuthKey_XXXX.p8 (PEM)
//   APNS_KEY_ID         — 10-char key id shown in Apple Developer
//   APNS_TEAM_ID        — 10-char team id
//   APNS_BUNDLE_ID      — com.datenow.app
//   APNS_HOST           — LEGACY fallback only — used when a row has no
//                         `apns_environment` set (should not happen
//                         after migration 20260526100000_device_tokens
//                         _apns_environment.sql). Default behaviour
//                         routes per-token: development tokens go to
//                         api.sandbox.push.apple.com, production tokens
//                         go to api.push.apple.com.
//   SUPABASE_URL        — auto-injected
//   SUPABASE_SERVICE_ROLE_KEY — auto-injected
//
// Until those secrets are present the function returns 503 — Apple
// never delivers anything and DateNow keeps working (the unread badge
// is enough). See docs/PUSH_NOTIFICATIONS_SETUP.md.
//
// Verbose logging: every step prints a `[push]` prefixed line so the
// Supabase Functions Logs tab tells the complete story (webhook
// received → recipient resolved → N tokens → M APNs status codes).
// =============================================================================

import { create as createJwt, getNumericDate } from "https://deno.land/x/djwt@v3.0.2/mod.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

interface MessagePayload {
  type: "INSERT";
  table: "messages";
  record: {
    id: string;
    conversation_id: string;
    sender_id: string;
    body: string;
    created_at: string;
  };
  schema: "public";
  old_record: null;
}

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

function jsonResponse(status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  const startedAt = Date.now();
  console.log(
    `[push] >>> ${req.method} ${new URL(req.url).pathname} ` +
      `from ${req.headers.get("x-forwarded-for") ?? "?"}`,
  );

  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") {
    console.warn(`[push] reject — method ${req.method} not allowed`);
    return new Response("method not allowed", { status: 405, headers: CORS });
  }

  // ── Secrets ────────────────────────────────────────────────────────────
  const apnsKey = Deno.env.get("APNS_KEY");
  const apnsKeyId = Deno.env.get("APNS_KEY_ID");
  const apnsTeamId = Deno.env.get("APNS_TEAM_ID");
  const apnsBundleId = Deno.env.get("APNS_BUNDLE_ID");
  const legacyApnsHost = Deno.env.get("APNS_HOST") ?? "api.push.apple.com";
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  console.log(
    `[push] secrets check — apns_key=${!!apnsKey} key_id=${!!apnsKeyId} ` +
      `team_id=${!!apnsTeamId} bundle=${!!apnsBundleId} ` +
      `legacy_host=${legacyApnsHost} ` +
      `supa_url=${!!supabaseUrl} service_key=${!!serviceKey}`,
  );
  if (!apnsKey || !apnsKeyId || !apnsTeamId || !apnsBundleId) {
    console.error("[push] abort — apns secrets missing");
    return jsonResponse(503, {
      ok: false,
      error: "apns_not_configured",
      hint: "Set APNS_KEY / APNS_KEY_ID / APNS_TEAM_ID / APNS_BUNDLE_ID secrets.",
    });
  }
  if (!supabaseUrl || !serviceKey) {
    console.error("[push] abort — SUPABASE_URL / SERVICE_ROLE_KEY missing");
    return jsonResponse(500, { ok: false, error: "supabase_env_missing" });
  }

  // ── Parse webhook body ─────────────────────────────────────────────────
  let raw: string;
  try {
    raw = await req.text();
  } catch (e) {
    console.error(`[push] abort — could not read body: ${e}`);
    return jsonResponse(400, { ok: false, error: "no_body" });
  }
  console.log(
    `[push] body (${raw.length} bytes): ${raw.slice(0, 1000)}` +
      (raw.length > 1000 ? "…" : ""),
  );

  let payload: MessagePayload;
  try {
    payload = JSON.parse(raw) as MessagePayload;
  } catch (e) {
    console.error(`[push] abort — invalid JSON: ${e}`);
    return jsonResponse(400, { ok: false, error: "invalid_json" });
  }

  console.log(
    `[push] parsed — type=${payload?.type} schema=${payload?.schema} ` +
      `table=${payload?.table} record_id=${payload?.record?.id} ` +
      `conv=${payload?.record?.conversation_id} ` +
      `sender=${payload?.record?.sender_id}`,
  );

  if (payload?.table !== "messages" || payload?.type !== "INSERT") {
    console.log("[push] ignored — payload is not messages/INSERT");
    return jsonResponse(200, {
      ok: true,
      ignored: true,
      reason: "not_messages_insert",
    });
  }
  if (!payload?.record?.conversation_id || !payload?.record?.sender_id) {
    console.warn("[push] ignored — missing conversation_id or sender_id");
    return jsonResponse(200, {
      ok: true,
      ignored: true,
      reason: "missing_record_fields",
    });
  }

  const supa = createClient(supabaseUrl, serviceKey);

  // ── Resolve recipient ──────────────────────────────────────────────────
  const { data: convo, error: convErr } = await supa
    .from("conversations")
    .select("id, user_a_id, user_b_id")
    .eq("id", payload.record.conversation_id)
    .single();
  if (convErr || !convo) {
    console.error(
      `[push] conversation lookup failed: code=${convErr?.code} ` +
        `message=${convErr?.message} details=${convErr?.details}`,
    );
    return jsonResponse(404, {
      ok: false,
      error: "conversation_not_found",
      conversation_id: payload.record.conversation_id,
    });
  }
  const recipientId =
    convo.user_a_id === payload.record.sender_id
      ? convo.user_b_id
      : convo.user_a_id;
  console.log(
    `[push] convo ${convo.id} — user_a=${convo.user_a_id} ` +
      `user_b=${convo.user_b_id} → recipient=${recipientId}`,
  );
  if (recipientId === payload.record.sender_id) {
    console.warn(
      "[push] sender == recipient (self-send) — no push",
    );
    return jsonResponse(200, { ok: true, ignored: true, reason: "self_send" });
  }

  // ── Resolve sender first name ─────────────────────────────────────────
  const { data: sender, error: senderErr } = await supa
    .from("profiles")
    .select("first_name")
    .eq("id", payload.record.sender_id)
    .single();
  if (senderErr) {
    console.warn(
      `[push] sender profile lookup error (continuing): ` +
        `code=${senderErr.code} message=${senderErr.message}`,
    );
  }
  const firstName =
    ((sender?.first_name as string | undefined) ?? "").trim() || "Quelqu'un";
  console.log(`[push] sender first_name = "${firstName}"`);

  // ── Look up device tokens ─────────────────────────────────────────────
  const { data: tokens, error: tokensErr } = await supa
    .from("device_tokens")
    .select("id, token, platform, apns_environment, updated_at")
    .eq("user_id", recipientId)
    .eq("platform", "ios")
    .not("token", "is", null);
  if (tokensErr) {
    console.error(
      `[push] device_tokens lookup failed: code=${tokensErr.code} ` +
        `message=${tokensErr.message} details=${tokensErr.details}`,
    );
    return jsonResponse(500, {
      ok: false,
      error: "device_tokens_lookup_failed",
      message: tokensErr.message,
    });
  }
  console.log(
    `[push] device_tokens for ${recipientId}: count=${tokens?.length ?? 0}`,
  );
  if (!tokens || tokens.length === 0) {
    console.warn(
      `[push] no iOS tokens for recipient=${recipientId} — nothing to send`,
    );
    return jsonResponse(200, {
      ok: true,
      pushed: 0,
      reason: "no_device_tokens",
      recipient_id: recipientId,
    });
  }
  console.log(
    `[push] tokens (suffix · env): ` +
      tokens
        .map((t: { token: string; apns_environment: string | null }) =>
          "…" + t.token.slice(Math.max(0, t.token.length - 6)) +
            "·" + (t.apns_environment ?? "legacy")
        )
        .join(", "),
  );

  // ── Sign APNs JWT ─────────────────────────────────────────────────────
  let jwt: string;
  try {
    const keyPem = apnsKey.includes("-----BEGIN")
      ? apnsKey
      : `-----BEGIN PRIVATE KEY-----\n${apnsKey}\n-----END PRIVATE KEY-----`;
    const keyPkcs8 = pemToArrayBuffer(keyPem);
    const cryptoKey = await crypto.subtle.importKey(
      "pkcs8",
      keyPkcs8,
      { name: "ECDSA", namedCurve: "P-256" },
      false,
      ["sign"],
    );
    jwt = await createJwt(
      { alg: "ES256", typ: "JWT", kid: apnsKeyId },
      { iss: apnsTeamId, iat: getNumericDate(0) },
      cryptoKey,
    );
    console.log(
      `[push] APNs JWT signed (kid=${apnsKeyId} iss=${apnsTeamId} ` +
        `len=${jwt.length})`,
    );
  } catch (e) {
    console.error(`[push] APNs JWT signing failed: ${e}`);
    return jsonResponse(500, {
      ok: false,
      error: "jwt_signing_failed",
      message: `${e}`,
    });
  }

  // ── Recipient unread badge ────────────────────────────────────────────
  // Total unread incoming messages for the recipient (includes the message
  // that just triggered this webhook). Sent as `aps.badge` so the iOS app
  // icon shows the real unread count. Mirrors the unread_messages_count() RPC
  // but for `recipientId` (the RPC is auth.uid()-scoped, unusable here).
  // Best-effort: on any failure we omit `badge` rather than send a wrong one.
  let badge: number | undefined;
  try {
    const { data: convs } = await supa
      .from("conversations")
      .select("id")
      .or(`user_a_id.eq.${recipientId},user_b_id.eq.${recipientId}`);
    const convIds = (convs ?? []).map((c: { id: string }) => c.id);
    if (convIds.length === 0) {
      badge = 0;
    } else {
      const { count, error: cntErr } = await supa
        .from("messages")
        .select("id", { count: "exact", head: true })
        .is("read_at", null)
        .neq("sender_id", recipientId)
        .in("conversation_id", convIds);
      if (cntErr) {
        console.warn(`[push] unread count failed (badge omitted): ${cntErr.message}`);
      } else {
        badge = count ?? 0;
      }
    }
    if (typeof badge === "number") {
      console.log(`[push] recipient unread badge = ${badge}`);
    }
  } catch (e) {
    console.warn(`[push] unread count threw (badge omitted): ${e}`);
  }

  const aps: Record<string, unknown> = {
    alert: { title: "DateNow", body: firstName },
    sound: "default",
  };
  if (typeof badge === "number") aps.badge = badge;
  const apnsPayload = JSON.stringify({
    aps,
    conversation_id: payload.record.conversation_id,
    sender_id: payload.record.sender_id,
    route: `/messages/${payload.record.conversation_id}`,
  });

  // ── Send one POST per token, routing to the matching APNs host ──────
  // Each row stores apns_environment ('development' | 'production'). A
  // sandbox token sent to api.push.apple.com (or vice-versa) returns
  // BadEnvironmentKeyInToken — so we pick the host per token rather
  // than relying on the legacy single APNS_HOST secret.
  //
  // Self-healing: if APNs replies with BadEnvironmentKeyInToken or
  // BadDeviceToken on the first attempt, we retry once on the *opposite*
  // host. If that retry succeeds the row in device_tokens is updated
  // so the next message lands on the right host immediately.
  const hostFor = (env: string | null | undefined): string => {
    switch (env) {
      case "development":
        return "api.sandbox.push.apple.com";
      case "production":
        return "api.push.apple.com";
      default:
        return legacyApnsHost;
    }
  };
  const flip = (env: string): { env: string; host: string } => {
    if (env === "development") {
      return { env: "production", host: "api.push.apple.com" };
    }
    return { env: "development", host: "api.sandbox.push.apple.com" };
  };
  const ENV_ERRORS = new Set([
    "BadEnvironmentKeyInToken",
    "BadDeviceToken",
  ]);

  type TokenRow = {
    id: string;
    token: string;
    apns_environment: string | null;
    updated_at: string;
  };

  async function postOnce(token: string, host: string) {
    const url = `https://${host}/3/device/${token}`;
    const r = await fetch(url, {
      method: "POST",
      headers: {
        "authorization": `bearer ${jwt}`,
        "apns-topic": apnsBundleId,
        "apns-push-type": "alert",
        "apns-priority": "10",
        "content-type": "application/json",
      },
      body: apnsPayload,
    });
    let bodyText = "";
    try {
      bodyText = await r.text();
    } catch (_) {
      // ignore
    }
    return {
      status: r.status,
      apnsId: r.headers.get("apns-id"),
      body: bodyText,
    };
  }

  const results = await Promise.all(
    tokens.map(async (row: TokenRow) => {
      const suffix = "…" + row.token.slice(Math.max(0, row.token.length - 6));
      const env = row.apns_environment ?? "legacy";
      const host = hostFor(row.apns_environment);
      console.log(
        `[push] using token row=${row.id} recipient=${recipientId} ` +
          `suffix=${suffix} env=${env} host=${host} updated_at=${row.updated_at}`,
      );
      try {
        const first = await postOnce(row.token, host);
        if (first.status === 200) {
          console.log(
            `[push] APNs OK row=${row.id} suffix=${suffix} env=${env} ` +
              `host=${host} apns-id=${first.apnsId}`,
          );
          return {
            row_id: row.id,
            token_suffix: suffix,
            env,
            host,
            status: 200,
            body: first.body,
            corrected: false,
          };
        }

        // Detect an environment / device-token mismatch and retry on
        // the opposite Apple host. Only attempt the retry when we have
        // a known env to flip (skip the legacy/null case).
        const looksLikeEnvErr = ENV_ERRORS.has(
          tryReadApnsReason(first.body),
        );
        const canFlip = row.apns_environment === "development" ||
          row.apns_environment === "production";

        if (looksLikeEnvErr && canFlip) {
          const target = flip(row.apns_environment as string);
          console.warn(
            `[push] APNs FAIL row=${row.id} suffix=${suffix} env=${env} ` +
              `host=${host} status=${first.status} body=${first.body} — ` +
              `retrying on host=${target.host} (env=${target.env})`,
          );
          const second = await postOnce(row.token, target.host);
          if (second.status === 200) {
            // Patch the row so subsequent pushes go to the right host.
            const { error: upErr } = await supa
              .from("device_tokens")
              .update({
                apns_environment: target.env,
                updated_at: new Date().toISOString(),
              })
              .eq("id", row.id);
            if (upErr) {
              console.error(
                `[push] env-correction db update FAILED row=${row.id} ` +
                  `code=${upErr.code} message=${upErr.message}`,
              );
            } else {
              console.log(
                `[push] corrected token env ${env} -> ${target.env} ` +
                  `after APNs retry OK (row=${row.id} suffix=${suffix})`,
              );
            }
            return {
              row_id: row.id,
              token_suffix: suffix,
              env: target.env,
              host: target.host,
              status: 200,
              body: second.body,
              corrected: true,
            };
          }
          console.error(
            `[push] retry on opposite host also FAILED row=${row.id} ` +
              `suffix=${suffix} status=${second.status} body=${second.body}`,
          );
          return {
            row_id: row.id,
            token_suffix: suffix,
            env,
            host: target.host,
            status: second.status,
            body: second.body,
            corrected: false,
            first_status: first.status,
            first_body: first.body,
          };
        }

        // Other APNs failure (Unregistered, TopicDisallowed,
        // InvalidProviderToken, …). Log and surface in the response.
        console.error(
          `[push] APNs FAIL row=${row.id} suffix=${suffix} env=${env} ` +
            `host=${host} status=${first.status} body=${first.body}`,
        );
        return {
          row_id: row.id,
          token_suffix: suffix,
          env,
          host,
          status: first.status,
          body: first.body,
          corrected: false,
        };
      } catch (e) {
        console.error(
          `[push] APNs network error row=${row.id} suffix=${suffix} ` +
            `env=${env} host=${host}: ${e}`,
        );
        return {
          row_id: row.id,
          token_suffix: suffix,
          env,
          host,
          status: 0,
          error: `${e}`,
          corrected: false,
        };
      }
    }),
  );

  const sent = results.filter((r) => r.status === 200).length;
  const corrected = results.filter((r) => r.corrected).length;
  const failed = results.length - sent;
  const tookMs = Date.now() - startedAt;
  console.log(
    `[push] <<< done — pushed=${sent}/${results.length} ` +
      `corrected=${corrected} failed=${failed} took=${tookMs}ms`,
  );
  return jsonResponse(200, {
    ok: true,
    tokens_count: results.length,
    pushes_sent: sent,
    pushes_corrected: corrected,
    pushes_failed: failed,
    took_ms: tookMs,
    results,
  });
});

// Extracts the "reason" field from Apple's APNs error body without
// throwing on malformed JSON (Apple occasionally truncates the body
// under load). Returns "" when the field is missing.
function tryReadApnsReason(body: string): string {
  if (!body) return "";
  try {
    const obj = JSON.parse(body) as { reason?: unknown };
    return typeof obj.reason === "string" ? obj.reason : "";
  } catch (_) {
    return "";
  }
}

// Minimal PEM → ArrayBuffer helper for the .p8 PKCS8 key.
function pemToArrayBuffer(pem: string): ArrayBuffer {
  const b64 = pem
    .replace(/-----BEGIN [^-]+-----/g, "")
    .replace(/-----END [^-]+-----/g, "")
    .replace(/\s+/g, "");
  const bin = atob(b64);
  const buf = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) buf[i] = bin.charCodeAt(i);
  return buf.buffer;
}
