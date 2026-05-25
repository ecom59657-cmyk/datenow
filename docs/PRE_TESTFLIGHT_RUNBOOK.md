# DateNow — Pre-TestFlight Runbook

**Date:** 24 May 2026
**Branch:** `ux/home-cta-nav`
**Audience:** the person archiving the build today.

The 6 steps that take DateNow from "code-ready" to "build queued in
TestFlight processing". Every command is exact. Anything irreversible
or production-touching is flagged ⚠ and includes a one-line description
of what changes.

Reference docs (don't duplicate, follow when deeper detail needed):
- `docs/APP_STORE_READINESS.md` — Apple Review mapping
- `docs/MVP_CLIENT_TEST_CHECKLIST.md` — full statique audit
- `docs/TESTFLIGHT_UPLOAD.md` — Xcode + App Store Connect deep dive
- `docs/TEST_PROTOCOL_MVP.md` — full 9-scenario 2-phone protocol

---

## Status snapshot (captured 2026-05-24, post-deploy)

| Item | State |
|------|-------|
| Supabase CLI | ✅ installed (2.100.0) |
| Project linked | ✅ `acastkbndpygowltemzp` (`DateNowProject`) |
| Migration `20260524120000_app_store_compliance.sql` | ✅ applied (Local = Remote) |
| Migration `20260525120000_available_dates.sql` | ⚠ **pending — run §1.5** |
| Edge Function `generate-agora-token` | ✅ ACTIVE (v2) |
| Edge Function `delete-account` | ✅ ACTIVE (v1, deployed 2026-05-24) |
| Secret `AGORA_APP_ID` | ✅ present |
| Secret `AGORA_APP_CERTIFICATE` | ✅ present |
| Secret `SUPABASE_SERVICE_ROLE_KEY` | ✅ present |
| pubspec version | ✅ `0.1.0+3` |
| iOS release bundle id | ✅ `com.datenow.app` |
| `flutter analyze` | ✅ 0 erreurs |
| `flutter test` | ✅ 35/35 |
| `flutter build ios --release --no-codesign` | ✅ `Runner.app (129.6MB)` |

> ℹ️ During push, the migration was made self-contained to recreate
> `public.reports` defensively — the remote had `20260513120000`
> marked applied but the `reports` table was missing (initial schema
> file was extended after first apply). Now resilient to that drift.

Server side fully ready. Remaining: 2-iPhone smoke (§4) then archive (§5) + upload (§6).

---

## 1. ⚠ Apply the compliance migration

**Command:**
```bash
supabase db push
```

**What it does (read first):**
- Adds 3 columns to `profiles`: `is_banned BOOLEAN`, `banned_reason TEXT`,
  `moderation_status TEXT` (default `'active'`).
- Adds `reports_reason_check` CHECK constraint on `public.reports.reason`
  (7 enum values). Rejects any pre-existing row with a value outside
  the list — none exist today (table is empty in MVP).
- Re-creates RLS policy `reports_insert_self` to also enforce
  `reported_user_id <> auth.uid()`.
- Creates `block_user(p_user_id)` SECURITY DEFINER RPC.
- Creates `delete_my_account()` SECURITY DEFINER RPC.
- Replaces `claim_match(peer_id)` SECURITY DEFINER RPC with the same
  body **plus** a ban gate at the top (`RAISE 'account_suspended'` /
  `'peer_unavailable'`).

**Idempotent?** Yes — every statement is `IF NOT EXISTS` / `DO $$ … END` /
`CREATE OR REPLACE`. Re-running is a no-op.

**Verify:**
```bash
supabase migration list --linked
# 20260524120000 should now appear under BOTH "Local" and "Remote".
```

---

## 1.5 ⚠ Apply the available-dates migration

**Command:**
```bash
supabase db push
```

**What it does (read first):**
- Adds RPC `available_date_proposals_today()` — SECURITY DEFINER, STABLE,
  returns `int`. Counts peers who are reachable RIGHT NOW for the Home
  "dates proposés aujourd'hui" stat: fresh presence (`user_presence`
  online/searching, <60 s heartbeat), `profiles.is_banned = false`,
  `moderation_status = 'active'`, not blocked in either direction
  (`blocked_users`), not already on another live `calls` row.
- Re-creates `claim_match(uuid)` with a new `peer_busy` gate: refuses
  the match if the target peer is on a live call with a third party.
  Same JSONB shape on success — clients see this as a one-off
  `PostgrestException` and the matching screen's poll loop retries with
  the next candidate.

**Verification:**
```bash
supabase migration list --linked
# 20260525120000 should appear under BOTH "Local" and "Remote".
```

You can also run `supabase/tests/flow_checks.sql` in the SQL editor —
the `fn available_date_proposals_today()` row must read PASS.

**If you skip this:** the Home tile silently shows "Aucun date
disponible pour l'instant" (RPC missing → null → empty state). No
crash, no app store rejection — but the new feature is dormant.

---

## 2. ⚠ Deploy the `delete-account` Edge Function

**Command:**
```bash
supabase functions deploy delete-account
```

**What it does:**
- Bundles `supabase/functions/delete-account/index.ts` and uploads it.
- The function (re-read it before deploy) does:
  1. Authenticates the caller from their JWT.
  2. Calls `delete_my_account()` RPC under the user's session (RLS-safe
     data wipe — cascade fans out to every dependent table).
  3. Calls `auth.admin.deleteUser(userId)` with
     `SUPABASE_SERVICE_ROLE_KEY` to remove the auth row so the email
     can be reused.
- Does **not** touch `generate-agora-token` (separate function).

**Verify:**
```bash
supabase functions list
# Expected: delete-account ACTIVE alongside generate-agora-token.
```

---

## 3. ✅ Secrets — already complete

`supabase secrets list` (run earlier) confirmed all 3 required:
- `AGORA_APP_ID` ✓
- `AGORA_APP_CERTIFICATE` ✓
- `SUPABASE_SERVICE_ROLE_KEY` ✓

No action needed. *(Note: `DAILY_API_KEY` is leftover from an earlier
video-provider experiment and is referenced nowhere in code. Safe to
ignore or delete with `supabase secrets unset DAILY_API_KEY`.)*

---

## 4. 2-iPhone smoke test (pre-archive)

Run **before** archiving so a bug doesn't ship to TestFlight. Use the
**debug** build (`flutter run --release -d <iphone>`) so any issue is
reproducible immediately. Two distinct DateNow accounts on two
physical iPhones.

### Setup
- ☐ Two iPhones, both updated to iOS 17+.
- ☐ Two accounts created with different emails and **compatible profile
  preferences** (verify with Debug → Matching → score ≥ 75 %).
- ☐ Both iPhones on stable Wi-Fi (any peer-to-peer test depends on it).

### A. Matching → single call → same channel
| # | Action | Expected |
|---|--------|----------|
| A1 | Sign in on both phones | Home screen reached, no debug overlay in release builds |
| A2 | Phone A: tap "Trouver un date" | Matching screen, "recherche" phase |
| A3 | Phone B: same within 10 s | Phone B also enters search |
| A4 | Wait for auto-match | Both transition to "Connexion du date…" |
| A5 | Both reach the live screen | Each sees the other's blurred video, audio works |
| A6 | Debug → Call card on both | `call_id` identical, `channel_name = dn_<call_id>` identical, `status = live` |

🔴 **Bloquant** : si `channel_name` diffère ou si deux `calls` rows existent.

### B. Caméra / micro / flou
| # | Action | Expected |
|---|--------|----------|
| B1 | First date ever on a phone | iOS prompts FR caméra (`NSCameraUsageDescription`) then micro |
| B2 | Both grant | Video + audio flow |
| B3 | Inspect rendered video | Visible blur (sigma 15) over the entire frame |
| B4 | Caption visible | "Caméra floutée jusqu'à la fin du date" displayed |
| B5 | Tap mute, then camera off, then back on | UIKit buttons all respond, peer banner reflects state |

🔴 **Bloquant** : flou absent ou caméra noire.

### C. Timer / fin auto / reveal
| # | Action | Expected |
|---|--------|----------|
| C1 | Watch the timer | Counts down from 5:00, identical to ≤ 2 s on both phones |
| C2 | Let it expire | Both auto-end at 0:00, navigate to PostCallScreen |
| C3 | Both tap "Révéler" | Mutual reveal — photo HD du peer (pas la sienne) débloquée, "C'est un match" |
| C4 | Debug → Reveal card | `outcome = mutual`, `match permanent créé = true`, `conversation créée = oui` |

🔴 **Bloquant** : photo de soi affichée (régression du bug §8 du MVP_CLIENT_TEST_CHECKLIST), pas de match, pas de conversation.

### D. Chat
| # | Action | Expected |
|---|--------|----------|
| D1 | Onglet Messages | Conversation visible des 2 côtés |
| D2 | Phone A envoie un message | Phone B le reçoit via Realtime |
| D3 | Phone B répond | A le reçoit |
| D4 | Phone B fait défiler vers le bas, ouvre la conv | Le badge unread se vide |

### E. Signalement (NOUVEAU — compliance)
| # | Action | Expected |
|---|--------|----------|
| E1 | Sur PostCallScreen, tap drapeau dans AppBar | Bottom sheet "Signaler" s'ouvre |
| E2 | Choisir "Harcèlement" + cocher "Bloquer aussi" | Bouton "Envoyer le signalement" actif |
| E3 | Envoyer | Snackbar "Merci, notre équipe examinera ce signalement.", sheet fermée |
| E4 | Vérifier Supabase Studio → Table `reports` | 1 nouvelle ligne avec `reason = 'harassment'`, `reporter_id` = soi, `reported_user_id` = peer |
| E5 | Vérifier Supabase Studio → Table `blocked_users` | 1 nouvelle ligne avec `user_id` = soi, `blocked_user_id` = peer |
| E6 | Refaire la conv (Messages → la conv) → ⋮ → Signaler | Même sheet, fonctionne pareil |

### F. Suppression de compte (NOUVEAU — compliance)
| # | Action | Expected |
|---|--------|----------|
| F1 | Réglages → "Supprimer mon compte" | Dialog rouge "Supprimer définitivement" |
| F2 | Confirmer | Snackbar "Compte supprimé", redirection auth landing |
| F3 | Vérifier Supabase Studio | Ligne `profiles` disparue, `auth.users` disparue, `matchmaking_queue`/`user_presence` vides pour ce user |
| F4 | Tenter de se reconnecter avec l'email supprimé | Échec attendu (compte n'existe plus) |
| F5 | Réinscription avec le même email | Réussit (auth row libérée) |

🟠 **Majeur** : Apple vérifie cette étape lors de la review.

> ⚠ **Test F destructeur** — utiliser un compte jetable, pas un compte
> de l'équipe.

---

## 5. Archive Xcode

Procédure complète : `docs/TESTFLIGHT_UPLOAD.md` §3. Résumé exécutable :

```bash
# Repartir propre
flutter clean
flutter pub get

# Build release (signé)
flutter build ios --release

# Ouvrir le workspace (PAS le .xcodeproj)
open ios/Runner.xcworkspace
```

Dans Xcode :
1. Scheme **Runner**, cible **Any iOS Device (arm64)**.
2. Onglet *Signing & Capabilities* du target **Runner** :
   - Cocher *Automatically manage signing*
   - Team = `LUDW9MH7BS`
3. **Product → Archive**.
4. Quand l'archive apparaît dans Organizer : **Validate App** d'abord.
   - Si erreur de provisioning : laisser Xcode régénérer le profil.
5. **Distribute App** → *App Store Connect* → *Upload* → laisser les
   options par défaut (Automatic signing + symbols inclus) → **Upload**.
6. Attendre "Upload Successful".

**Pré-requis :** une app DateNow doit exister dans App Store Connect
avec le bundle id `com.datenow.app` (étape §6).

---

## 6. App Store Connect — premier upload

### a. Créer l'app (une seule fois)
- App Store Connect → **My Apps** → **+** → **New App**.
- Platform: **iOS**
- Name: **DateNow**
- Primary language: **French**
- Bundle ID: `com.datenow.app` (déjà enregistré côté Apple Developer)
- SKU: `datenow-mvp` (libre, juste un identifiant interne)
- User Access: Full Access

### b. Compléter App Privacy (compliance Apple)
App Store Connect → DateNow → **App Privacy** → **Get Started**.

Pour chaque type de donnée, déclarer collected/linked/tracking
(détails dans `docs/APP_STORE_READINESS.md` §1) :

| Data type | Collected | Linked to user | Tracking |
|-----------|-----------|----------------|----------|
| Email | Yes | Yes | No |
| Name (first name) | Yes | Yes | No |
| Birth date | Yes | Yes | No |
| Sexual orientation | Yes | Yes | No |
| Photos | Yes | Yes | No |
| Audio (live, not stored) | Yes | Yes | No |
| Video (live, not stored) | Yes | Yes | No |
| Messages (user content) | Yes | Yes | No |
| Crash data / performance | Yes | No | No |

**Privacy Policy URL** : `https://datenow.app/privacy` (héberger le
contenu de `docs/privacy_policy.md` à cette adresse, ou rediriger).

### c. Age Rating
App Store Connect → DateNow → **App Information** → **Age Rating** → **Edit**.

Cocher au minimum :
- *Frequent/Intense Mature/Suggestive Themes* — yes (dating)
- *User-Generated Content* — yes (chat, photos, profil)
- *Unrestricted Web Access* — no

Résultat attendu : **17+**.

### d. TestFlight — testeurs internes (immédiat)
App Store Connect → DateNow → **TestFlight** → **Internal Testing** :
- Créer un groupe (ex. *Équipe DateNow*).
- Ajouter les comptes (jusqu'à 100, doivent être membres de la team
  Apple Developer).
- Le build apparaît au statut *Processing* (~10 min) puis *Ready to
  Test*. Lien d'invitation envoyé automatiquement.

### e. TestFlight — testeurs externes (Beta Review Apple)
- TestFlight → **External Testing** → créer un groupe (ex. *Amis*).
- Renseigner :
  - **Description** — quoi tester (matching → date vidéo → reveal).
  - **Email contact** — `support@datenow.app`.
  - **What to Test** — la liste §4 A→F de ce runbook (raccourcir si besoin).
- Ajouter testeurs par email **ou** activer le **lien public**
  `https://testflight.apple.com/join/XXXXXXXX`.
- Le **premier** build externe passe une **Beta App Review** Apple
  (généralement < 24 h). Les suivants du même groupe sont souvent
  validés sans nouvelle revue.

### f. Erreurs Apple Review fréquentes (anticipation)

| Symptôme | Cause probable | Fix |
|----------|----------------|-----|
| "Cannot reproduce login" | Reviewer n'a pas de compte | Fournir un demo account dans App Review Information |
| "No way to delete account" | Reviewer ne trouve pas le bouton | Pointer Réglages → Supprimer mon compte dans les notes |
| "Inadequate content moderation" | Reviewer ne voit pas Signaler | Pointer post-call → drapeau, conv → ⋮ → Signaler |
| "Privacy policy mismatch" | Différence in-app vs URL | S'assurer que `https://datenow.app/privacy` est en ligne |
| "Age gate insufficient" | Pas de date de naissance demandée | Confirmer que sign-up demande `birth_date` (déjà le cas) |
