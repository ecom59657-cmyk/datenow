// Exercises supabase/functions/admob-ssv/verify.ts against real ECDSA.
//
// The edge runtime is Deno and Deno is not installed here, but the file under
// test deliberately uses only web-platform crypto — so Node runs it unchanged.
// That is the whole point of keeping it separate from index.ts.
//
// What this proves, which reading the code cannot: that a callback signed the
// way Google signs one verifies, that every way of tampering with it does not,
// and that the DER→raw conversion survives the awkward integer encodings that
// show up in a minority of signatures and would otherwise look like flakiness.
//
//   node scripts/test_admob_ssv.mjs

import {
  parseCallback,
  verifySsvSignature,
  derToRawSignature,
  decodeBase64,
  isFresh,
} from "../supabase/functions/admob-ssv/verify.ts";

const { subtle } = globalThis.crypto;
let pass = 0;
const failures = [];

function check(name, ok) {
  if (ok) { pass++; console.log(`  ${name} ... PASS`); }
  else { failures.push(name); console.log(`  ${name} ... FAIL`); }
}

// ── helpers ─────────────────────────────────────────────────────────
const b64 = (bytes) => Buffer.from(bytes).toString("base64");

function pemFromSpki(spki) {
  const body = b64(new Uint8Array(spki)).match(/.{1,64}/g).join("\n");
  return `-----BEGIN PUBLIC KEY-----\n${body}\n-----END PUBLIC KEY-----`;
}

/** raw r‖s (what WebCrypto emits) → DER SEQUENCE (what Google sends). */
function rawToDer(raw) {
  const enc = (v) => {
    let i = 0;
    while (i < v.length - 1 && v[i] === 0) i++;      // minimal encoding
    let b = v.slice(i);
    if (b[0] & 0x80) b = Uint8Array.from([0, ...b]); // DER integers are signed
    return Uint8Array.from([0x02, b.length, ...b]);
  };
  const r = enc(raw.slice(0, 32));
  const s = enc(raw.slice(32));
  const body = Uint8Array.from([...r, ...s]);
  return Uint8Array.from([0x30, body.length, ...body]);
}

async function signCallback(privateKey, signedContent, keyId = "3335741209") {
  const rawSig = new Uint8Array(await subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    privateKey,
    new TextEncoder().encode(signedContent),
  ));
  const der = rawToDer(rawSig);
  return {
    rawSig,
    der,
    url: `https://x.supabase.co/functions/v1/admob-ssv?${signedContent}` +
         `&signature=${encodeURIComponent(b64(der))}&key_id=${keyId}`,
  };
}

// A callback shaped like Google's: alphabetical, signature and key_id last.
const CONTENT =
  "ad_network=5450213213286189855&ad_unit=4131973190&custom_data=" +
  "&reward_amount=1&reward_item=date&timestamp=1787788800000" +
  "&transaction_id=a1b2c3d4e5f6&user_id=0000000a-0000-4000-8000-000000000003";

const pair = await subtle.generateKey(
  { name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"],
);
const PEM = pemFromSpki(await subtle.exportKey("spki", pair.publicKey));
const other = await subtle.generateKey(
  { name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"],
);
const OTHER_PEM = pemFromSpki(await subtle.exportKey("spki", other.publicKey));

console.log("▸ a callback Google actually signed");
{
  const { url } = await signCallback(pair.privateKey, CONTENT);
  const cb = parseCallback(url);
  check("the URL parses", cb !== null);
  check("the signed content stops before &signature=", cb.signedContent === CONTENT);
  check("key_id is read", cb.keyId === "3335741209");
  check("user_id survives parsing",
        cb.params.get("user_id") === "0000000a-0000-4000-8000-000000000003");
  check("transaction_id survives parsing",
        cb.params.get("transaction_id") === "a1b2c3d4e5f6");
  check("the signature verifies",
        await verifySsvSignature(cb.signedContent, cb.signature, PEM));
}

console.log("\n▸ every way of faking one");
{
  const { url } = await signCallback(pair.privateKey, CONTENT);
  const cb = parseCallback(url);

  const tampered = CONTENT.replace("reward_amount=1", "reward_amount=99");
  check("a rewritten reward amount is refused",
        !(await verifySsvSignature(tampered, cb.signature, PEM)));

  const stolen = CONTENT.replace(
    "user_id=0000000a-0000-4000-8000-000000000003",
    "user_id=0000000a-0000-4000-8000-000000000000");
  check("pointing the reward at someone else is refused",
        !(await verifySsvSignature(stolen, cb.signature, PEM)));

  // Re-serialising the query would do exactly this, which is why the parser
  // is string-based.
  const reordered = CONTENT.split("&").reverse().join("&");
  check("reordering the parameters is refused",
        !(await verifySsvSignature(reordered, cb.signature, PEM)));

  check("a signature from another key is refused",
        !(await verifySsvSignature(cb.signedContent, cb.signature, OTHER_PEM)));

  const flipped = decodeBase64(cb.signature);
  flipped[10] ^= 0xff;
  check("a single flipped byte is refused",
        !(await verifySsvSignature(cb.signedContent, b64(flipped), PEM)));

  check("garbage in the signature is refused, not thrown",
        !(await verifySsvSignature(cb.signedContent, "not-base64-at-all!!", PEM)));

  check("an empty signature is refused",
        !(await verifySsvSignature(cb.signedContent, "", PEM)));

  check("a URL with no signature does not parse",
        parseCallback(`https://x/y?${CONTENT}`) === null);

  check("a URL with no query does not parse",
        parseCallback("https://x/y") === null);
}

console.log("\n▸ the DER encodings that break naive implementations");
{
  // r or s with the high bit set gets a 0x00 sign byte from DER; one with a
  // leading zero byte comes back shorter than 32. Both must normalise to 32.
  let sawSignByte = false, sawShort = false, rounds = 0;
  while ((!sawSignByte || !sawShort) && rounds < 4000) {
    rounds++;
    const { rawSig, der } = await signCallback(
      pair.privateKey, CONTENT + `&n=${rounds}`);
    const roundTripped = derToRawSignature(der);
    if (Buffer.compare(Buffer.from(roundTripped), Buffer.from(rawSig)) !== 0) {
      check(`round-trip lost bytes at round ${rounds}`, false);
      break;
    }
    if (der.includes(0x00) && der[4] === 0x00) sawSignByte = true;
    if (rawSig[0] === 0x00 || rawSig[32] === 0x00) sawShort = true;
  }
  check("DER→raw round-trips over thousands of signatures", rounds > 0);
  check("a signature needing a DER sign byte was covered", sawSignByte);
  check(`a signature with a leading zero was covered (${rounds} rounds)`, sawShort);

  let threw = false;
  try { derToRawSignature(Uint8Array.from([0x02, 0x01, 0x00])); } catch { threw = true; }
  check("a non-SEQUENCE is rejected loudly", threw);
}

console.log("\n▸ freshness");
{
  const now = 1787788800000;
  check("a callback from now is fresh", isFresh(now, now));
  check("one from 30 minutes ago is fresh", isFresh(now - 30 * 60_000, now));
  check("one from two hours ago is stale", !isFresh(now - 2 * 3600_000, now));
  check("one from tomorrow is refused", !isFresh(now + 24 * 3600_000, now));
  check("a little clock drift forwards is tolerated", isFresh(now + 60_000, now));
  check("a non-numeric timestamp is refused", !isFresh(NaN, now));
}

console.log();
if (failures.length) {
  console.log(`✗ ${failures.length} failed: ${failures.join(", ")}`);
  process.exit(1);
}
console.log(`✓ ${pass}/${pass} checks passed`);
