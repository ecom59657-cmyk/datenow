// =============================================================================
// DateNow — AdMob rewarded SSV signature verification
//
// Kept apart from index.ts and free of any Deno-specific import, because the
// only interesting thing in this function is the cryptography and it has to
// be testable outside the edge runtime. Everything below runs on the web
// platform APIs (crypto.subtle, TextEncoder, atob) that Deno and Node share
// — see scripts/test_admob_ssv.mjs, which signs a callback with a throwaway
// P-256 key and runs it through this exact file.
//
// The protocol, from developers.google.com/admob/android/ssv :
//
//   * Google appends `signature` and `key_id` as the LAST two query
//     parameters, in that order.
//   * What is signed is the raw query string up to — not including —
//     `&signature=`. Byte for byte, order untouched.
//   * The algorithm is ECDSA over SHA-256 on P-256.
//   * The public keys live at https://gstatic.com/admob/reward/verifier-keys.json
//     and rotate; they must not be cached longer than 24 hours.
//
// The trap: Google emits the signature in ASN.1 DER (a SEQUENCE of two
// INTEGERs), while WebCrypto's ECDSA verify expects the raw r‖s pair of 64
// bytes. Feeding DER straight to verify() returns false for every callback,
// which reads exactly like a wrong key.
// =============================================================================

export interface SsvCallback {
  /** The bytes Google signed: the query string before `&signature=`. */
  signedContent: string;
  /** Base64 (standard or URL alphabet), still DER-encoded. */
  signature: string;
  /** Which verifier key to check it against. */
  keyId: string;
  /** Parsed parameters, for the caller's business logic. */
  params: URLSearchParams;
}

/**
 * Splits a callback URL into the part that was signed and the signature.
 *
 * Deliberately string-based rather than rebuilt from URLSearchParams:
 * re-serialising would re-encode characters and change the bytes, and the
 * signature would never match again.
 */
export function parseCallback(rawUrl: string): SsvCallback | null {
  const q = rawUrl.indexOf("?");
  if (q < 0) return null;
  const query = rawUrl.slice(q + 1);

  const marker = query.indexOf("&signature=");
  if (marker < 0) return null;

  const signedContent = query.slice(0, marker);
  const params = new URLSearchParams(query);
  const signature = params.get("signature");
  const keyId = params.get("key_id");
  if (!signature || !keyId) return null;

  return { signedContent, signature, keyId, params };
}

/** Base64 in either alphabet, with or without padding. */
export function decodeBase64(input: string): Uint8Array {
  let s = input.replace(/-/g, "+").replace(/_/g, "/");
  while (s.length % 4 !== 0) s += "=";
  const bin = atob(s);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

/**
 * ASN.1 DER `SEQUENCE { INTEGER r, INTEGER s }` → the raw 64-byte r‖s pair
 * WebCrypto wants.
 *
 * DER INTEGERs are signed and minimally encoded, so r and s arrive with a
 * leading 0x00 when their top bit is set, and shorter than 32 bytes when
 * they have leading zero bytes. Both cases have to be normalised to a fixed
 * 32 bytes or verification fails on roughly half of all signatures — the
 * kind of bug that looks like flakiness.
 */
export function derToRawSignature(der: Uint8Array): Uint8Array {
  let i = 0;
  if (der[i++] !== 0x30) throw new Error("der_not_a_sequence");

  let seqLen = der[i++];
  if (seqLen & 0x80) {
    // Long form: the low bits say how many bytes carry the length.
    const n = seqLen & 0x7f;
    seqLen = 0;
    for (let k = 0; k < n; k++) seqLen = (seqLen << 8) | der[i++];
  }
  if (i + seqLen !== der.length) throw new Error("der_length_mismatch");

  const readInt = (): Uint8Array => {
    if (der[i++] !== 0x02) throw new Error("der_not_an_integer");
    const len = der[i++];
    const bytes = der.slice(i, i + len);
    i += len;
    return bytes;
  };

  const pad32 = (b: Uint8Array): Uint8Array => {
    // Drop the sign byte DER adds, then left-pad to the curve's 32 bytes.
    let start = 0;
    while (start < b.length - 1 && b[start] === 0x00) start++;
    const trimmed = b.slice(start);
    if (trimmed.length > 32) throw new Error("der_integer_too_long");
    const out = new Uint8Array(32);
    out.set(trimmed, 32 - trimmed.length);
    return out;
  };

  const r = pad32(readInt());
  const s = pad32(readInt());

  const raw = new Uint8Array(64);
  raw.set(r, 0);
  raw.set(s, 32);
  return raw;
}

/** PEM public key → the SPKI DER bytes importKey expects. */
export function pemToSpki(pem: string): Uint8Array {
  const body = pem
    .replace(/-----BEGIN [^-]+-----/g, "")
    .replace(/-----END [^-]+-----/g, "")
    .replace(/\s+/g, "");
  return decodeBase64(body);
}

export async function importVerifierKey(pem: string): Promise<CryptoKey> {
  return await crypto.subtle.importKey(
    "spki",
    pemToSpki(pem),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["verify"],
  );
}

/**
 * True only when [signature] is Google's over [signedContent] under [pem].
 *
 * Never throws on a malformed signature — a caller that has to distinguish
 * "invalid" from "crashed" would end up treating a crash as a pass.
 */
export async function verifySsvSignature(
  signedContent: string,
  signature: string,
  pem: string,
): Promise<boolean> {
  try {
    const key = await importVerifierKey(pem);
    const raw = derToRawSignature(decodeBase64(signature));
    return await crypto.subtle.verify(
      { name: "ECDSA", hash: "SHA-256" },
      key,
      raw,
      new TextEncoder().encode(signedContent),
    );
  } catch {
    return false;
  }
}

/**
 * How old a callback may be before we stop trusting it, in milliseconds.
 *
 * Google retries for a while, so this cannot be tight; an hour keeps a
 * captured URL from being replayed days later without rejecting legitimate
 * retries. The unique index on the transaction id is what actually stops a
 * replay — this only bounds the window.
 */
export const MAX_CALLBACK_AGE_MS = 60 * 60 * 1000;

export function isFresh(
  timestampMs: number,
  nowMs: number,
  maxAgeMs = MAX_CALLBACK_AGE_MS,
): boolean {
  if (!Number.isFinite(timestampMs)) return false;
  const age = nowMs - timestampMs;
  // A little slack forwards: clocks drift, and Google's is not ours.
  return age >= -5 * 60 * 1000 && age <= maxAgeMs;
}
