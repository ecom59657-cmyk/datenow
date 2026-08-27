# AdMob server-side verification — setup (manual steps)

The rewarded video grants one extra date. Until SSV, the app told the server
"I watched it" and the server believed it. Now Google tells the server, over a
signed callback, and only once the user really finished the video. The app has
no grant of its own any more — `grant_quota_bonus()` is revoked from
`authenticated` by migration `20260827110000`.

That last sentence is also the trap: **once the migration is applied, no bonus
can be granted until the callback URL is configured in AdMob.** Deploy in the
order below.

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

## Deploy order

Doing these out of order costs you every reward in between.

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

**After deploying** — watch a rewarded video on a real device, then:

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
