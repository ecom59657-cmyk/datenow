# Push notifications — setup (manual steps)

Real iOS push notifications require Apple Developer Console action +
Xcode capability changes + Supabase secrets. The code in this repo
already lays the scaffold (table, Edge Function, dormant client hook).
This doc lists what's still TODO to flip delivery on.

## What's already in the repo

| Layer | Status |
|---|---|
| `device_tokens` table + RLS | ✅ migration `20260525160000_push_notifications.sql` (run `supabase db push`) |
| Edge Function `message-notification` (APNs HTTP/2, JWT-signed) | ✅ `supabase/functions/message-notification/index.ts` (deploy with `supabase functions deploy message-notification`) |
| In-app snackbar / sound on new message | ❌ **removed** — push is the new path. Unread badge stays. |
| Token storage client-side | ⏸ TODO — see § "Flutter integration" below |
| Permission request UX | ⏸ TODO — `permission_handler.Permission.notification.request()` after first match or first Messages tab open |
| iOS Push Notifications capability + Background Modes | ⏸ TODO — Xcode steps below |
| APNs key + Supabase secrets | ⏸ TODO — Apple + `supabase secrets set` below |

## ⚠ Apple Developer Console

1. Sign in to <https://developer.apple.com/account>.
2. **Certificates, Identifiers & Profiles → Keys → +**.
3. Name: `DateNow APNs`. Tick **Apple Push Notifications service (APNs)**.
4. **Continue → Register**. Download `AuthKey_<KEY_ID>.p8` (one-shot — save it offline).
5. Note the **Key ID** (10 chars, shown after creation) and the **Team ID** (top-right of the page).
6. **Identifiers → App IDs → com.datenow.app → Edit → Capabilities** → tick **Push Notifications → Save**.

## ⚠ Xcode capability

1. `open ios/Runner.xcworkspace`
2. *Runner* target → **Signing & Capabilities** → **+ Capability**:
   - **Push Notifications**
   - **Background Modes** → tick **Remote notifications**
3. Re-archive (the entitlements change is part of the build).

## ⚠ Supabase secrets

```bash
supabase secrets set \
  APNS_KEY="$(cat ~/Downloads/AuthKey_XXXXXXXXXX.p8)" \
  APNS_KEY_ID="XXXXXXXXXX" \
  APNS_TEAM_ID="LUDW9MH7BS" \
  APNS_BUNDLE_ID="com.datenow.app" \
  APNS_HOST="api.push.apple.com"
```

> Use `api.sandbox.push.apple.com` for TestFlight debug builds, `api.push.apple.com` for App Store / production builds. TestFlight release builds typically use `api.push.apple.com`.

## ⚠ Supabase webhook

In the Supabase dashboard:

1. **Database → Webhooks → Create a new hook**.
2. Name: `messages_notify`.
3. Table: `public.messages`. Events: **INSERT**. Type: HTTP Request.
4. URL: `https://<your-project>.functions.supabase.co/message-notification`.
5. HTTP headers: `authorization: Bearer <SUPABASE_SERVICE_ROLE_KEY>`.

Then deploy the Edge Function once:

```bash
supabase functions deploy message-notification
```

## ⚠ Flutter integration (still to add)

To complete the loop, pick one of:

- **`firebase_messaging`** (recommended for cross-platform later). Adds a Firebase project + `GoogleService-Info.plist`. FCM-via-APNs receives the device token, which is registered in `device_tokens`. ⚠ adds Firebase dep.
- **Native plugin (`flutter_apns_only` / custom)**. Direct APNs registration via `UIApplication.registerForRemoteNotifications()` in `AppDelegate.swift`, expose token to Dart via a `MethodChannel`. ⚠ requires custom Swift.

Whichever you pick, the Flutter side must:

1. Request `Permission.notification` from `permission_handler` (already in pubspec).
2. On grant, register for remote notifications + capture the APNs device token (hex string).
3. INSERT into `device_tokens` (`user_id`, `platform: 'ios'`, `token`).
4. On notification tap with payload `{ "route": "/messages/<id>" }`, deep-link via GoRouter (`/messages/:id` already exists).
5. On sign-out: DELETE the row to stop receiving pushes.

## Privacy

The push payload contains **only**:
- `title: "DateNow"`
- `body: "<sender first name>"`
- `conversation_id`, `sender_id`, `route` (for deep link)

The message body, last_message_preview, photo URL, anything else — **never** in the push. The recipient app fetches the real conversation through Supabase Realtime after the user opens it.

## Verification

Once Apple + Xcode + Supabase steps are done:

```sql
-- Run in Supabase SQL editor:
SELECT
  'fn message-notification deployed' AS check,
  CASE WHEN EXISTS (SELECT 1 FROM supabase_functions.hooks WHERE function = 'message-notification')
       THEN 'PASS' ELSE 'FAIL' END AS status
UNION ALL
SELECT 'table device_tokens',
  CASE WHEN to_regclass('public.device_tokens') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END;
```

Then send a test message from peer A to peer B. Peer B's iPhone should buzz with **"DateNow — <peer A first name>"** and tapping opens the chat. Until you complete the Apple-side work the function returns 503 `apns_not_configured`.
