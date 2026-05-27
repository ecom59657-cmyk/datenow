# Auth — external configuration (Apple, Google, Supabase)

This is the manual setup that completes auth sub-phases D + E. The
client-side code is shipped; without this config the OAuth buttons
will compile and render but fail at the system sheet step.

Constants you'll reference repeatedly:

```
Bundle ID                : com.datenow.app
Team ID                  : LUDW9MH7BS
Supabase project ref     : acastkbndpygowltemzp
Supabase auth callback   : https://acastkbndpygowltemzp.supabase.co/auth/v1/callback
App-side linking callback: io.supabase.flutter://login-callback
```

---

## 1. Apple Developer Console — Sign in with Apple

1. <https://developer.apple.com/account> → Certificates, Identifiers & Profiles.
2. **Identifiers → App IDs → `com.datenow.app` → Edit**:
   - Capabilities → enable **Sign In with Apple** → Save.
3. **Identifiers → Services IDs → +** :
   - Description: `DateNow Auth`
   - Identifier: `com.datenow.app.auth` (any unique reverse-DNS — note it).
   - Continue → tick **Sign In with Apple** → Configure :
     - Primary App ID: `com.datenow.app`
     - Domains: `acastkbndpygowltemzp.supabase.co`
     - Return URLs: `https://acastkbndpygowltemzp.supabase.co/auth/v1/callback`
   - Save → Continue → Register.
4. **Keys → +**:
   - Key Name: `DateNow Sign in with Apple`
   - Tick **Sign In with Apple** → Configure → Primary App ID `com.datenow.app` → Save.
   - Continue → Register → **Download** the `.p8` file (one-shot — save offline next to your APNs `.p8`).
   - Note the **Key ID** (10 chars, top of the page).

Outcome — gather these for the Supabase form:
- Services ID: `com.datenow.app.auth`
- Team ID: `LUDW9MH7BS`
- Key ID: (10-char value shown after key creation)
- `.p8` file content (full PEM, including `-----BEGIN`/`END PRIVATE KEY-----`)

---

## 2. Google Cloud Console — OAuth 2.0

1. <https://console.cloud.google.com> → create project `DateNow` (or reuse the Firebase Messaging project — recommended so iOS clients share one project).
2. **APIs & Services → OAuth consent screen**:
   - User type: External
   - App name: DateNow
   - User support email: `privacy@datenow.app`
   - Authorized domains: `acastkbndpygowltemzp.supabase.co`
   - Scopes: `openid`, `email`, `profile`
   - Test users: add your test emails OR submit for verification (Production status required before public TestFlight).
3. **Credentials → + Create Credentials → OAuth client ID**:
   - **iOS client**:
     - Application type: iOS
     - Name: `DateNow iOS`
     - Bundle ID: `com.datenow.app`
     - Note **iOS Client ID** + **Reversed Client ID** (auto-derived: `com.googleusercontent.apps.<digits>`).
   - **Web client** (Supabase needs this):
     - Application type: Web application
     - Name: `DateNow Supabase`
     - Authorized JavaScript origins: leave empty
     - Authorized redirect URIs: `https://acastkbndpygowltemzp.supabase.co/auth/v1/callback`
     - Note **Web Client ID** + **Web Client Secret**.

Outcome:
- iOS Client ID: `<digits>-<hash>.apps.googleusercontent.com`
- Reversed Client ID: `com.googleusercontent.apps.<digits>-<hash>`
- Web Client ID + Web Client Secret (for Supabase Dashboard).

---

## 3. iOS — Info.plist + GoogleService-Info.plist

### `ios/Runner/Info.plist`

Find the placeholder block we shipped in sub-phase E:

```xml
<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleURLSchemes</key>
    <array>
      <!-- TODO: replace once Google iOS OAuth client is created. -->
      <string>com.googleusercontent.apps.PLACEHOLDER_REVERSED_CLIENT_ID</string>
    </array>
  </dict>
</array>
```

Replace `PLACEHOLDER_REVERSED_CLIENT_ID` with the **Reversed Client ID** from step 2. Final shape:

```xml
<string>com.googleusercontent.apps.123456789012-abcdefghijklmnop</string>
```

### `ios/Runner/GoogleService-Info.plist`

This is the file already in the repo (Firebase Messaging setup). It probably does NOT have `CLIENT_ID` / `REVERSED_CLIENT_ID` because we initially enabled only Cloud Messaging.

Two options to refresh it:

**Option A — Firebase Console (recommended)**:
1. Firebase Console → Project Settings → Your apps → iOS app `com.datenow.app`.
2. If "Google Sign-In" isn't enabled, add it. Firebase auto-creates the OAuth iOS client.
3. Download the updated `GoogleService-Info.plist` → replace the file in `ios/Runner/`.

**Option B — Manual edit**:
Add these keys (the values match what Google Cloud Console showed):

```xml
<key>CLIENT_ID</key>
<string>123456789012-abcdefghijklmnop.apps.googleusercontent.com</string>
<key>REVERSED_CLIENT_ID</key>
<string>com.googleusercontent.apps.123456789012-abcdefghijklmnop</string>
```

Either way, the file MUST contain both keys for `google_sign_in` to pick them up on iOS.

---

## 4. Supabase Dashboard

### Auth → Providers → Apple
- Toggle **Enable Apple provider** ON.
- **Services ID (for OAuth)**: `com.datenow.app.auth`
- **Team ID**: `LUDW9MH7BS`
- **Key ID**: (from step 1.4)
- **Secret Key (.p8)**: paste the full contents of `AuthKey_XXXXXXXX.p8`.
- Save.

### Auth → Providers → Google
- Toggle **Enable Google provider** ON.
- **Client ID (for OAuth)**: the **Web Client ID** from step 2.3.
- **Client Secret (for OAuth)**: the **Web Client Secret** from step 2.3.
- (Optional, for `signInWithIdToken` on iOS) — paste the **iOS Client ID** in "Skip nonce checks" *only if* you experience nonce mismatch (default OFF is correct).
- Save.

### Auth → URL Configuration
- **Site URL**: `io.supabase.flutter://login-callback`
- **Redirect URLs**: include `io.supabase.flutter://login-callback` (the Flutter Supabase SDK uses this scheme for the `linkIdentity` round-trip).
- Save.

### Auth → Email Templates
- (Already configured in sub-phase C) — the OTP template uses `{{ .Token }}` for the 6-digit code.

### Pre-test cleanup (per the user's plan)
Wipe existing accounts before the first real test:

```sql
DELETE FROM auth.users;
-- CASCADE wipes profiles, conversations, matches, calls, etc.
```

---

## 5. Validation checklist

After every config step above, verify:

| Check | Where | Pass criterion |
|---|---|---|
| Apple capability present | Xcode → Runner target → Signing & Capabilities | "Sign in with Apple" tile listed |
| Entitlement file correct | `ios/Runner/Runner.entitlements` | `com.apple.developer.applesignin = ["Default"]` |
| Apple .p8 in Supabase | Supabase Dashboard → Auth → Providers → Apple | Status "Enabled" |
| Google URL scheme | `ios/Runner/Info.plist` | `CFBundleURLSchemes` matches `com.googleusercontent.apps.<digits>-<hash>` (no PLACEHOLDER) |
| GoogleService-Info.plist | `plutil -p ios/Runner/GoogleService-Info.plist` | `CLIENT_ID` + `REVERSED_CLIENT_ID` both present |
| Google enabled in Supabase | Auth → Providers → Google | Status "Enabled" with Web Client ID |
| Redirect URLs | Auth → URL Configuration | `io.supabase.flutter://login-callback` allow-listed |
| Email OTP template | Auth → Email Templates → Magic Link | `{{ .Token }}` present |

---

## 6. Test procedure — real OAuth on iPhone via TestFlight

After the configuration is live in Supabase + the Info.plist swap is done:

1. **Bump version** (`pubspec.yaml`: 0.1.0+18 → 0.1.0+19 — next number).
2. `flutter clean && flutter pub get && cd ios && pod install && cd ..`
3. **Xcode** → Product → Archive → Distribute → App Store Connect → TestFlight.
4. Install on the iPhone via TestFlight (uninstall any previous build first to flush the Apple keychain entries for `com.datenow.app`).

### Test 1 — Apple Sign In, first time
- Tap **Continuer avec Apple**.
- Apple sheet → choose "Share my email" → Face ID.
- Expected:
  - Console (macOS Console.app filtered on DateNow):
    - `[SupabaseAuth] signInWithApple — opening Apple sheet`
    - `[SupabaseAuth] Apple credential — userId=... has_name=true has_email=true`
    - `[SupabaseAuth] signInWithApple success — user=<uuid>`
    - `[SupabaseAuth] Apple givenName "<name>" pushed to user metadata`
  - SQL `SELECT id, email, raw_user_meta_data FROM auth.users WHERE id = '<uuid>';` → row with `first_name` set, no `birth_date`.
  - SQL `SELECT id, first_name, birth_date FROM profiles WHERE id = '<uuid>';` → row with `first_name` filled, `birth_date = NULL`.
  - App lands on Profile Setup → Cupertino picker for DOB → save → /home.

### Test 2 — Google Sign In, first time
- Sign out from Test 1 (Profile → Settings → Sign out).
- Tap **Continuer avec Google**.
- Google sheet → pick account.
- Expected logs + SQL rows: same shape, `provider = 'google'` in `auth.identities`.

### Test 3 — Apple Private Relay
- Sign out.
- Tap **Continuer avec Apple** with a fresh Apple ID → choose "Hide my email".
- Expected: account created with `email = <hash>@privaterelay.appleid.com`. Stays separate from the Test 1 account (no implicit merge — validated decision).

### Test 4 — Email OTP, first time
- Sign out.
- Tap **Continuer avec un email** → enter first_name + DOB + email → Continuer.
- Receive the 6-digit code by email.
- Enter the code → land on /home (profile complete because all fields were collected at signup).

### Test 5 — Voluntary linking
- Stay signed in as a Test 1 (Apple) user.
- Profile → Sécurité → Comptes liés.
- Tap **Lier Google** → in-app webview opens → Google → consent.
- Expected:
  - Snack "Compte lié".
  - `SELECT provider FROM auth.identities WHERE user_id = '<uuid>';` returns both `apple` and `google`.
  - The Email row in the same screen stays "Lié à ton compte" because the Apple email was auto-attached.

### Test 6 — Identity already in use
- Stay signed in as the Test 4 (email OTP) user.
- Profile → Sécurité → Tap **Lier Google** with a Google account whose email matches the Test 2 (Google-first) user.
- Expected: CupertinoActionSheet "Email déjà utilisé" with the body pointing to "sign in with that account, then link from Security". No snack, no Supabase stack trace.

### Test 7 — Cancel cases
- Tap **Continuer avec Apple** → tap "Cancel" on the system sheet.
- Expected: AuthLanding stays put, no snack, no error log.
- Idem for Google.

---

## 7. Remaining points before App Store Review

| # | Item | Status | Notes |
|---|---|---|---|
| 1 | Sign in with Apple capability enabled in App ID | ⏳ manual | step 1 above |
| 2 | Apple `.p8` uploaded to Supabase | ⏳ manual | step 4 above |
| 3 | Google iOS + Web OAuth clients created | ⏳ manual | step 2 above |
| 4 | `REVERSED_CLIENT_ID` swapped in Info.plist | ⏳ manual | step 3 above |
| 5 | GoogleService-Info.plist refreshed with CLIENT_ID | ⏳ manual | step 3 above |
| 6 | Google enabled in Supabase Auth Providers | ⏳ manual | step 4 above |
| 7 | OAuth consent screen submitted (External, Production) | ⏳ manual | step 2.2 above — required for public TestFlight |
| 8 | Email OTP template carries {{ .Token }} | ⏳ manual | step 4 above |
| 9 | `DELETE FROM auth.users` for clean test | ⏳ manual | step 4 above |
| 10 | Account deletion path tested | ✅ wired since sub-phase ≤C | Settings → Delete account → Edge Function deletes auth.users |
| 11 | Privacy + Terms accessible 1-tap from landing | ✅ already shipped | required by Apple Review |
| 12 | Age 18+ gate (4 layers) | ✅ already shipped | UI / Validator / CHECK / Trigger |
| 13 | Push notifications dSYM Agora warnings | ⚠ non-blocking | doc in `IOS_DSYM_NOTES.md` — Agora ships no dSYMs |
| 14 | Camera + Photos + Location usage strings | ✅ already shipped | French copy in Info.plist |
| 15 | Apple Sign In + Google parity on landing | ✅ already shipped | both buttons at the same hierarchy |
| 16 | Voluntary identity linking (no implicit merge) | ✅ already shipped | Security → Linked accounts |

When 1-9 are green, the build is a real App Store candidate.

---

## 8. After config — final verification chain

```bash
cd ~/datenow
flutter clean
flutter pub get
cd ios && pod install && cd ..
flutter analyze --no-pub        # expect 20 pre-existing infos, 0 errors
flutter test                     # expect 93/93 passed
flutter build ios --release --no-codesign  # expect ~94 MB
```

Then in Xcode:
1. Bump pubspec to next build number (`0.1.0+19` etc.).
2. Product → Archive.
3. Distribute App → App Store Connect → TestFlight Internal.
4. Wait for ingestion (5-15 min). Watch for dSYM warnings (Agora-only,
   non-blocking).
5. Install via TestFlight → run the 7 tests above.

If all 7 tests pass, the auth+permissions layer is ready for App
Store Review.
