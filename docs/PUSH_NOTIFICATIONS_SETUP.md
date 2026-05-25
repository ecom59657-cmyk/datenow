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
| Token storage client-side | ✅ `lib/core/notifications/push_notifications_service.dart` — Firebase Messaging as the APNs bridge, upserts (`user_id`, `token`) into `device_tokens`, deep-links on tap |
| Permission request UX | ✅ One-shot sheet on first Messages tab visit (`SharedPreferences` flag `push_perm_asked`) |
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

## ⚠ Firebase Console setup (one-time, manual)

The Flutter side uses `firebase_messaging` as the iOS APNs bridge. To
activate it you must create a free Firebase project and drop the iOS
config plist into the repo:

1. Go to <https://console.firebase.google.com> → **Add project**.
2. Name: `DateNow` (or `DateNow Prod`). Disable Google Analytics (we
   don't want it).
3. In the project → **iOS** icon to add an iOS app.
4. **Apple bundle ID**: `com.datenow.app`. App nickname: `DateNow iOS`.
5. **Download `GoogleService-Info.plist`**.
6. Drop the file into `ios/Runner/` (the same folder as `Info.plist`).
   This file is git-ignored by default — every dev needs their own
   download from the Firebase Console.
7. Upload the APNs auth key (`.p8`) to Firebase Console **Project
   Settings → Cloud Messaging → Apple app config → APNs Authentication
   Key → Upload**. Use the same key you already pushed to Supabase
   secrets (`AuthKey_NA82N9J467.p8`).
   *Note*: Firebase needs this so its iOS native SDK can register the
   device with APNs (we still send the actual pushes ourselves via the
   Edge Function — Firebase here is just a token broker).

That's it for the Firebase side. Re-run `cd ios && pod install` once
the plist is in place, then re-archive.

## ⚠ Flutter integration — what's already wired

- `firebase_core` + `firebase_messaging` added to `pubspec.yaml`.
- `PushNotificationsService.initialize()` is called from `main.dart`.
  If `GoogleService-Info.plist` is missing, init is silently skipped
  (push features become a no-op — app still works).
- On first Messages tab visit, a one-shot bottom sheet asks the user
  whether to enable notifications. Tapping *Activer* fires the iOS
  system prompt, then:
  - `FirebaseMessaging.requestPermission()` →
  - `getAPNSToken()` →
  - upsert into `device_tokens` (`platform: 'ios'`, `user_id`, `token`,
    `updated_at`).
- `onTokenRefresh` listens for APNs token rotations (reinstall, restore,
  prod ↔ debug swap) and re-upserts.
- `onMessageOpenedApp` + `getInitialMessage` route the tap to
  `/messages/<conversation_id>` via the global `rootNavigatorKey` (cold
  start retries each frame until the router is mounted).

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
