# DateNow — App Store / TestFlight Readiness

**Date:** 24 May 2026
**Branch audited:** `ux/home-cta-nav`
**Scope:** minimum Apple App Store compliance for a dating app with
live video on iPhone. No new product features — only the safety
plumbing Apple Review and platform policy require.

This document is the index. Detailed checklists live in:
- `docs/MVP_CLIENT_TEST_CHECKLIST.md` — full MVP readiness audit
- `docs/TESTFLIGHT_UPLOAD.md` — upload procedure
- `docs/BUILD_MOBILE_CHECKLIST.md` — iOS / Android build setup
- `docs/TEST_PROTOCOL_MVP.md` — 2-iPhone test scenarios
- `docs/privacy_policy.md` — public-facing privacy policy

---

## 0. Verdict

| Apple-review concern | Status |
|----------------------|--------|
| Privacy policy reachable in-app + as URL | ✅ in `PrivacyPolicyScreen` + `docs/privacy_policy.md` |
| Privacy / Terms one tap from sign-up | ✅ links on AuthLanding + SignUp footer |
| In-app account deletion (App Store guideline 5.1.1(v)) | ✅ Settings → Supprimer mon compte → Edge Function `delete-account` |
| Reporting mechanism for objectionable content (1.2) | ✅ `Signaler` on PostCall + Conversation, 7-reason enum |
| Block mechanism (1.2) | ✅ `block_user` RPC + opt-in via report sheet + BlockedAccountsScreen unblock |
| Age gate 18+ (1.3 / 5.1) | ✅ 4-layer enforcement (UI / repo / trigger / CHECK) + `MinorBlockedScreen` |
| Minor reporting (1.2 / safety) | ✅ "Profile appears to be a minor" report category |
| Moderation tooling (banned account state) | ✅ `profiles.is_banned` + `claim_match` server gate |
| Camera / microphone usage strings (Info.plist) | ✅ FR user-facing strings, no `Agora` jargon |
| Secrets not shipped in client | ✅ `AGORA_APP_CERTIFICATE` server-only, `SUPABASE_SERVICE_ROLE_KEY` server-only |
| Debug surfaces stripped in release | ✅ `kDebugMode` gates routes + logger + tile |
| Identity verification readiness (future Didit) | ✅ `IdentityVerificationService` abstraction ready, mock active |

---

## 1. Privacy Policy

### In-app
- `lib/features/settings/presentation/legal/privacy_policy_screen.dart`
  — 11 sections covering collect / use / Agora / photos / sharing /
  moderation / minors / deletion / security / retention / contact.
- Reachable from: **Settings → Privacy Policy**, **AuthLanding footer**,
  **SignUp footer**.

### Public document
- `docs/privacy_policy.md` — host on the marketing site at
  `https://datenow.app/privacy` and supply that URL in App Store Connect
  → **App Privacy → Privacy Policy URL**.

### Apple-required Privacy details (App Store Connect)
Declare in App Store Connect → App Privacy:

| Data type | Linked to user? | Tracking? | Purpose |
|-----------|-----------------|-----------|---------|
| Email | Yes | No | App functionality, Customer support |
| Name (first name) | Yes | No | App functionality |
| Birth date | Yes | No | App functionality (age gate) |
| Sexual orientation | Yes | No | App functionality (matching) |
| Photos | Yes | No | App functionality |
| Audio data (live, not stored) | Yes | No | App functionality |
| Video data (live, not stored) | Yes | No | App functionality |
| User content (messages) | Yes | No | App functionality |
| Crash data / performance | No | No | App functionality |

---

## 2. Account deletion (App Store guideline 5.1.1(v))

### Path
**Settings → Supprimer mon compte → confirmation dialog → wipe**

### Implementation
1. Client invokes the `delete-account` Edge Function with the user JWT.
2. Function calls the `delete_my_account()` SECURITY DEFINER RPC under
   the user's session — this wipes `matchmaking_queue`, `user_presence`,
   ends live calls, then `DELETE FROM profiles` which cascades to:
   - `user_preferences`, `user_photos`, `weekly_suggestions`,
   - `matches`, `calls`, `blocked_users`, `reports` (reporter side),
   - `conversations` + `messages` (via FK cascade),
   - `reveals`, `subscriptions`, `user_settings`.
3. Function then calls `auth.admin.deleteUser(userId)` with the
   `SUPABASE_SERVICE_ROLE_KEY` to remove the `auth.users` row so the
   email can be reused.
4. Client signs out — router redirects to `/auth`.

### Edge Function secrets
The function requires three Supabase secrets — set them once with:
```bash
supabase secrets set SUPABASE_SERVICE_ROLE_KEY=...   # required, new
# SUPABASE_URL and SUPABASE_ANON_KEY are usually already present
```

### Edge Function deploy
```bash
supabase functions deploy delete-account
```

### Reviewer evidence
Apple's reviewer will look for a clearly labelled "Delete my account"
action that requires confirmation and surfaces a clear outcome. We
have all three (confirmation dialog, snackbar on success, snackbar on
failure).

---

## 3. Reporting and moderation (App Store guideline 1.2)

### Report flow (`Signaler` / `Report`)
- Entry points:
  - **PostCallScreen** — AppBar flag icon, visible while a match
    context exists (between the date and the reveal).
  - **ConversationScreen** — three-dot menu → Signaler.
- Bottom sheet (`lib/features/safety/presentation/report_sheet.dart`):
  1. Pick one of 7 reasons (enum-backed, server CHECK enforced):
     `inappropriate_behavior`, `nudity_sexual`, `harassment`, `minor`,
     `fake_profile`, `spam`, `other`.
  2. Optional 500-char details field.
  3. **"Also block this person"** checkbox (default on) — calls
     `block_user(p_user_id)` RPC in the same step.
  4. Confirmation snackbar: *"Merci, notre équipe examinera ce
     signalement."*

### Server side
- Table `public.reports` (existed pre-MVP):
  `reporter_id, reported_user_id, reason, details, status, created_at`.
- New CHECK on `reason` — only the 7 enum values accepted.
- RLS: `reports_insert_self` rewritten to enforce
  `reporter_id = auth.uid()` AND `reported_user_id <> auth.uid()`
  (cannot self-report).
- `block_user(p_user_id)` SECURITY DEFINER RPC also force-ends any
  live call between blocker and blocked.

### Suspended accounts
- `profiles.is_banned` + `profiles.moderation_status` columns
  (`'active' | 'suspended' | 'banned'`).
- `claim_match` RPC raises `account_suspended` if the caller is banned
  and `peer_unavailable` if the target is banned — client never reaches
  the call screen.
- Admin (operator) flips `is_banned = true` in the Supabase dashboard
  for the MVP. A full moderation console is out of scope.

---

## 4. Protection of minors (App Store guidelines 1.3 / 5.1)

### Age gate — defense in depth
| Layer | File | Mechanism |
|-------|------|-----------|
| 1. UI validator | `lib/core/utils/age.dart` `isOfMinimumAge` | block submit |
| 2. Repository | `auth_repository.dart` `signUpWithPassword` | throws `MinorSignUpFailure` |
| 3. DB trigger | `handle_new_user()` | re-checks, RAISE on minor |
| 4. CHECK constraint | `profiles_min_age_18` | unconditional |

### Minor-blocked UX
- `lib/features/safety/presentation/minor_blocked_screen.dart`
  — calm screen explaining the 18+ rule + contact email for appeal.
- Shown after a `MinorSignUpFailure` (current path: snackbar; future
  path: inline screen swap-in).

### Minor reporting
- Dedicated report category **`Profil semble mineur`** / **`Profile
  appears to be a minor`** in the report sheet.
- Treated as priority server-side (admin runbook).

### Identity verification (future)
- `lib/features/safety/domain/identity_verification_service.dart`
  abstraction is ready; a `MockIdentityVerificationService` returns
  `notRequired` for the MVP.
- Production wiring (Didit / Veriff / Onfido) swaps the provider in
  one line — no consumer code change.

---

## 5. Block + unblock

- **Block**: from the report sheet (default-on checkbox) → `block_user`
  RPC → inserts into `blocked_users`, ends any live call.
- **Unblock**: existing `BlockedAccountsScreen` (Settings → Blocked
  accounts) — currently uses the mock settings repository; wire to the
  Supabase impl when a user reports needing it (out of MVP scope).
- RLS on `blocked_users` already restricts read/write to the blocker.

---

## 6. iOS Info.plist usage strings (already in place)

| Key | Value (FR) |
|-----|------------|
| `NSCameraUsageDescription` | "DateNow utilise la caméra pour vos dates vidéo de 5 minutes et pour ajouter votre photo de profil." |
| `NSMicrophoneUsageDescription` | "DateNow utilise le micro pendant vos dates vidéo en direct de 5 minutes." |
| `NSPhotoLibraryUsageDescription` | "DateNow accède à vos photos pour que vous puissiez choisir votre photo de profil." |

No mentions of "Agora" or other vendor names — Apple rejects vague /
technical descriptions in review.

---

## 7. Secrets posture (no client leaks)

- `AGORA_APP_CERTIFICATE` — server-only (Supabase secret), never
  referenced in `lib/`. Enforced by `release_safety_test.dart`.
- `SUPABASE_SERVICE_ROLE_KEY` — server-only (new, used by
  `delete-account`). Never referenced in `lib/`.
- `AGORA_APP_ID` — public (per Agora docs), shipped in `.env`.
- `SUPABASE_ANON_KEY` — public-by-design (RLS protects it), shipped
  in `.env`.
- `.env` itself is `.gitignore`'d and was never committed.

---

## 8. Debug surface stripped from release

| Surface | Gate |
|---------|------|
| `/debug-datenow` route | `if (kDebugMode)` in `app_router.dart` |
| `/debug-matching` route | idem |
| Debug tile in Settings | `if (kDebugMode)` in `settings_screen.dart` |
| `AppLogger.info/warn/error` | `if (!kDebugMode) return;` in `logger.dart` |
| OBS test overlay | `kDebugMode` only |

Static guard: `test/release_safety_test.dart` fails the build if any
gate is removed.

---

## 9. Migrations & deploys required before TestFlight

```bash
# 1. Apply the compliance migration on the remote project.
supabase db push

# 2. Deploy the new Edge Function.
supabase functions deploy delete-account

# 3. Confirm secrets — generate-agora-token + delete-account.
supabase secrets list
#   AGORA_APP_ID                 (set previously)
#   AGORA_APP_CERTIFICATE        (set previously)
#   SUPABASE_SERVICE_ROLE_KEY    (NEW — required for delete-account)
```

If `SUPABASE_SERVICE_ROLE_KEY` is missing, the Edge Function returns
`500 delete_not_configured` and the in-app delete action surfaces a
clean error.

---

## 10. App Store Connect submission cues

- **Privacy Policy URL** — `https://datenow.app/privacy`.
- **App Privacy → Data Used to Track You** — leave empty (we don't).
- **Age Rating** — set to **17+** (dating + user-generated content +
  unrestricted web/video).
- **Content Rights** — confirm you have rights to all stock content.
- **TestFlight test notes** — mention that the app requires two real
  testers signing in simultaneously to reach the video flow.
- **Demo account** — provide one to the reviewer; the moderation flow
  (file a report from a conversation) is the easiest piece to demo.

---

## 11. Known limitations (acceptable for TestFlight)

- **Blocked-accounts SettingsRepository** uses the in-memory mock by
  default; the Supabase implementation of `watchBlockedUsers` /
  `unblockUser` throws `UnimplementedError` and is not wired to the
  Supabase project yet. Block insertions land in the DB via
  `block_user()`. The unblock UX needs the Supabase impl once a user
  asks for it.
- **Banned-account screen** — server gate is enforced
  (`claim_match → 'account_suspended'`), but no dedicated "your account
  is suspended" screen has been built. The user will see the error
  surface as a snackbar.
- **Identity verification** is intentionally stubbed; the
  `MockIdentityVerificationService` returns `notRequired`.
- **PostCallScreen photo** — fixed in a prior task (peer photo, not the
  current user's). See `MVP_CLIENT_TEST_CHECKLIST.md` §8.

None of these block App Review for a TestFlight beta or first MVP
submission; address them iteratively based on reviewer feedback / user
reports.
