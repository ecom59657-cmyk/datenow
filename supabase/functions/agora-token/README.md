# `agora-token` Edge Function

Signs short-lived Agora RTC tokens server-side. The App **Certificate** is
the cryptographic secret used to sign — **never** check it into git and
never ship it inside Flutter.

## Set up

1. Create (or grab) your Agora project at <https://console.agora.io>:
   - **App ID** — public, embed in `.env` as `AGORA_APP_ID=`
   - **Primary Certificate** — server-only, kept in Supabase secrets

2. Store the secrets:

   ```bash
   supabase secrets set \
     AGORA_APP_ID=<your-app-id> \
     AGORA_APP_CERTIFICATE=<your-primary-certificate>
   ```

   `SUPABASE_URL` and `SUPABASE_ANON_KEY` are already populated by Supabase
   automatically inside Edge Functions, no need to set them.

3. Deploy:

   ```bash
   supabase functions deploy agora-token --no-verify-jwt
   ```

   `--no-verify-jwt` keeps GoTrue from rejecting the request before our
   own auth check runs — we still verify the user inside the function and
   return a friendly 401 instead of GoTrue's HTML error.

## How the client talks to it

```dart
final res = await supabase.functions.invoke('agora-token', body: {
  'channelName': 'dn-<sortedConcat-of-user-ids>',
  'uid': userIdHash, // int32, derived from the caller's user id
});
```

The function answers:

```json
{
  "token": "006...",
  "appId": "<public app id>",
  "channelName": "dn-<...>",
  "uid": 1234567,
  "expiresAt": 1718296800
}
```

The token is valid for **10 minutes** — well above the 5-minute call cap.

## Auth model

- The function is gated by `supabase.auth.getUser()` — anonymous callers
  get `401`.
- The function checks that `channelName` contains the caller's user id
  (with dashes stripped). The Flutter client builds the channel as
  `dn-<sorted-pair-of-user-ids>` so this naturally holds for legitimate
  joins and blocks attempts to grab a token for someone else's channel.

## Local development

```bash
supabase functions serve agora-token --env-file .env.local
```

Where `.env.local` (gitignored) contains `AGORA_APP_ID` and
`AGORA_APP_CERTIFICATE`. The Flutter client will then hit
`http://localhost:54321/functions/v1/agora-token`.
