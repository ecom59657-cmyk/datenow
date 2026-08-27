# AdMob server-side verification — setup (manual steps)

The rewarded video grants one extra date. Until SSV, the app told the server
"I watched it" and the server believed it. Now Google tells the server, over a
signed callback, and only once the user really finished the video. The app has
no grant of its own any more — `grant_quota_bonus()` is revoked from
`authenticated` by migration `20260827110000`.

That last sentence carries the trap, but only under one condition: **the order
below matters once a build containing this client code is in users' hands.**
Between the migration landing and the callback URL being registered, a live app
would let people watch videos for nothing.

It does not matter while no such build is published. The migrations were
applied on 2026-08-27 while the App Store still carried 0.2.0+74, which
predates all of this and calls none of it — so the order was safely reversed
there. Check what is actually live before deciding you are in a hurry.

## What's already in the repo

| Layer | Status |
|---|---|
| `quota_bonuses` table, RLS, no write policy | ✅ `20260827100000_quota_server_side.sql` |
| `grant_quota_bonus_ssv(uuid, text)`, service_role only | ✅ `20260827110000_quota_bonus_ssv.sql` |
| Revoke of the client's self-grant | ✅ same migration |
| `admob-ssv` Edge Function (signature check + grant) | ✅ `supabase/functions/admob-ssv/` |
| Client sends `userId` to Google | ✅ `RewardedAdService.showAndAwaitReward` |
| Client waits for the grant instead of making it | ✅ `SupabaseQuotaRepository.awaitRewardedBonus` |
| Callback URL registered in the AdMob console | ❌ **manual, see below** |

## What is already deployed

As of 2026-08-27, on project `acastkbndpygowltemzp`:

| | |
|---|---|
| Both migrations | ✅ applied via the SQL Editor, and recorded in `supabase_migrations.schema_migrations` so the CLI stays in step |
| `admob-ssv` function | ✅ deployed, **Verify JWT off**, at `https://acastkbndpygowltemzp.supabase.co/functions/v1/admob-ssv` |
| Callback URL in AdMob | ❌ still to do |

Smoke-tested from outside with no valid signature — the four answers that say
it is wired correctly:

| Request | Answer | What it proves |
|---|---|---|
| no query at all | `400 malformed` | the function runs; Verify JWT really is off |
| unknown `key_id` | `401 bad_signature` | it reaches Google's key server |
| real `key_id`, junk signature | `401 bad_signature` | it loaded the live public key and ran the ECDSA check |
| three-hour-old timestamp | `401 bad_signature` | the signature is checked *before* freshness — unsigned data is never read |

A `503 key_server_unreachable` in place of the second answer would mean the
edge runtime cannot reach gstatic.com.

## Deploy order

Doing these out of order costs you every reward in between — see the caveat at
the top for when that is actually true.

### Without the CLI

Everything below can be done from the dashboard, which is how it was done the
first time (the CLI session had expired and `supabase login` needs a TTY):

* **Migrations** — SQL Editor → New query → paste each file from
  `supabase/migrations/` → Run. They are written to be re-runnable
  (`CREATE OR REPLACE`, `IF NOT EXISTS`, `DROP POLICY IF EXISTS`), so a
  double-run is harmless. Afterwards, record them by hand or the next
  `supabase db push` will try to replay them:

  ```sql
  insert into supabase_migrations.schema_migrations (version, name)
  values ('20260827100000', 'quota_server_side'),
         ('20260827110000', 'quota_bonus_ssv')
  on conflict (version) do nothing;
  ```

* **Function** — Edge Functions → Deploy a new function → *Via editor*. Two
  things the editor will let you get wrong: the code must go in **`index.ts`**
  (a second file beside it is never the entry point), and the **function name
  field defaults to a random one** like `dynamic-api`. A wrongly named function
  works, but the CLI would later deploy `admob-ssv` beside it and leave the
  original live and registered with Google — edits then land on an endpoint
  nobody calls.

  The editor cannot see `../_shared`, so paste the single-file build instead of
  `index.ts` from the repo. Regenerate it by inlining the four helpers from
  `supabase/functions/_shared/`.

### With the CLI

### 1. Deploy the function first, while the old grant still works

```bash
supabase functions deploy admob-ssv --no-verify-jwt
```

`--no-verify-jwt` is required and is not a shortcut: Google does not carry a
Supabase JWT. The ECDSA signature *is* the authentication, which is what makes
it safe to leave the endpoint open. Deploying without the flag returns 401 to
Google on every callback and silently drops every reward.

Note the URL it prints:

```
https://<project-ref>.supabase.co/functions/v1/admob-ssv
```

### 2. Register that URL in AdMob

AdMob console → **Apps** → DateNow (iOS) → **Ad units** → the rewarded unit
(`ca-app-pub-7977656042089301/4131973190`) → **Server-side verification** →
paste the URL → Save.

Google starts calling it within a few minutes. Watch:

```bash
supabase functions logs admob-ssv --tail
```

A healthy line reads `callback settled … granted=true`.

### 3. Only then, apply the migrations

```bash
supabase db push
```

This is the irreversible half: the client loses its self-grant. If step 2 is
not done, users watch videos and get nothing.

## Verifying it works

**Before deploying** — the signature path is exercised locally against real
ECDSA, with a throwaway P-256 key:

```bash
node scripts/test_admob_ssv.mjs      # 25 checks
./scripts/test_quota_sql.sh          # 49 checks, throwaway Postgres
```

**A debug build cannot test this at all.** `AdIds` switches to Google's public
test units whenever `kReleaseMode` is false, and those units belong to Google —
there is nowhere to attach your callback URL. No callback will ever arrive, and
it looks exactly like a broken endpoint. The first real test needs a **release**
build (TestFlight) running the live ad unit.

**After deploying** — watch a rewarded video on a release build, then:

```sql
select user_id, granted_on, verified, ssv_transaction_id, granted_at
  from quota_bonuses
 order by granted_at desc
 limit 5;
```

A row with `verified = true` and a non-null `ssv_transaction_id` is a reward
Google vouched for. A row with `verified = false` predates SSV or was inserted
by hand for support.

## How it actually works

Google appends `signature` and `key_id` as the last two query parameters. What
is signed is the raw query string up to — not including — `&signature=`, byte
for byte, order untouched. The algorithm is ECDSA over SHA-256 on P-256, and
the public keys live at `https://gstatic.com/admob/reward/verifier-keys.json`,
rotating on a variable schedule (cached for an hour here, Google's ceiling is
24).

The one thing worth knowing if you ever touch `verify.ts`: **Google sends the
signature in ASN.1 DER, WebCrypto expects raw `r‖s`.** Handing DER straight to
`crypto.subtle.verify` returns false for every callback, which looks exactly
like a wrong key and sends you hunting in the wrong place.
`scripts/test_admob_ssv.mjs` covers the awkward DER integer encodings that
only show up in a minority of signatures.

## Limits, deliberate

- **Three bonuses a day, per user.** Enforced in
  `grant_quota_bonus_ssv`. Google will not send a fourth callback anyway;
  the ceiling is there for the day it does.
- **Replays are free.** A redelivered `transaction_id` returns
  `{granted:true, replay:true}` and writes nothing — the unique partial index
  on `ssv_transaction_id` is the real guard.
- **Callbacks older than an hour are ignored**, so a captured URL cannot be
  replayed days later.
- **A callback with no `user_id` is accepted and dropped.** It means the app
  failed to set `ServerSideVerificationOptions`; retrying will not conjure a
  user, so it answers 200 rather than making Google retry for hours.
- **Android is not registered in AdMob at all** — `AdIds.isConfigured` is
  false there, the button hides itself, and no callback will ever arrive.

## Support: handing back a lost date

`grant_quota_bonus()` still exists and is still callable by `service_role`,
for the case where a callback is genuinely lost. From the SQL editor:

```sql
select public.grant_quota_bonus_ssv(
  '<user-uuid>', 'manual-' || gen_random_uuid()::text);
```

It counts against the same three-a-day ceiling.
