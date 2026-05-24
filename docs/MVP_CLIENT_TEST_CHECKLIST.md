# MVP Client Test Checklist — DateNow

**Date de l'audit :** 2026-05-24
**Branche auditée :** `ux/home-cta-nav` (HEAD `b4079f3`)
**Objectif :** valider que le MVP est prêt pour un premier test client réel
via Apple Developer / TestFlight.

Ce document consolide tout ce qu'il faut vérifier **avant**, **pendant**
et **après** un test 2-iPhones. Aucune modification de logique métier n'a
été faite : c'est un audit + un protocole.

Les checklists adjacentes restent valides et complémentaires :
- `docs/TESTFLIGHT_UPLOAD.md` — procédure d'upload pas-à-pas
- `docs/BUILD_MOBILE_CHECKLIST.md` — config iOS/Android détaillée
- `docs/TEST_PROTOCOL_MVP.md` — scénarios 2-phones étendus
- `docs/SMOKE_TEST_FINAL.md` — smoke test rapide
- `docs/PRE_REAL_TEST_REPORT.md` — rapport tests statiques
- `docs/AGORA_TOKEN_NOTE.md` — notes hardening Agora

---

## 0. Verdict global

| Section | Statut |
|---------|--------|
| 1. iOS / TestFlight | ✅ PASS (1 warning : voir §1) |
| 2. Secrets / Env | ✅ PASS |
| 3. Supabase (schéma, RLS, Realtime) | ✅ PASS (statique) — ⏸ NOT RUN (déploiement à confirmer) |
| 4. Agora (token, certificat, UID, channel) | ✅ PASS (statique) — ⏸ NOT RUN (token live à tester via curl) |
| 5. Test réel 2 iPhones | ⏸ NOT RUN — requiert 2 devices |
| 6. Visio / caméra / micro / flou | ⏸ NOT RUN — requiert 2 devices |
| 7. Timer / fin d'appel | ⏸ NOT RUN — requiert 2 devices |
| 8. Reveal / match / chat | ⏸ NOT RUN — requiert 2 devices |
| 9. Cas d'échec | ⏸ NOT RUN — requiert 2 devices |
| 10. `flutter analyze` | ✅ PASS (0 erreur, 14 info lint cosmétiques) |
| 10. `flutter test` | ✅ PASS (33/33) |
| 10. `flutter build ios --release --no-codesign` | ✅ PASS — `Built build/ios/iphoneos/Runner.app (129.4MB)` pour `com.datenow.app` en 237,9 s |

> **Verdict : 🟢 GO conditionnel.** Tout ce qui est vérifiable sans
> device est vert. Trois actions restent obligatoires avant l'envoi du
> lien TestFlight au client (cf. §11) — la plus importante est la **photo
> du peer affichée au reveal** (cf. §8, bug majeur connu).

---

## 1. Audit iOS / TestFlight

| Élément | Valeur observée | OK |
|---------|-----------------|----|
| Bundle ID **Release** (config TestFlight) | `com.datenow.app` (`project.pbxproj` ligne 725) | ✅ |
| Bundle ID **Profile** | `com.datenow.app` (ligne 505) | ✅ |
| Bundle ID **Debug** (dev local seulement) | `com.guims.datenow` (ligne 699) | ⚠ voir warning |
| RunnerTests | `com.guims.datenowTests` | ✅ (test, sans impact TestFlight) |
| `CFBundleDisplayName` | `DateNow` (`Info.plist` ligne 10) | ✅ |
| Version (pubspec.yaml) | `0.1.0+2` | ⚠ à incrémenter à chaque upload |
| `IPHONEOS_DEPLOYMENT_TARGET` | `15.1` (requis par Agora) | ✅ |
| `DEVELOPMENT_TEAM` (Release) | `LUDW9MH7BS` | ✅ |
| `CODE_SIGN_STYLE` (Release) | `Manual` | ✅ |
| `defaultConfigurationName` du target Runner | `Release` | ✅ |
| `NSCameraUsageDescription` | présent, FR, orienté utilisateur (pas de jargon « Agora ») | ✅ |
| `NSMicrophoneUsageDescription` | présent, FR | ✅ |
| `NSPhotoLibraryUsageDescription` | présent, FR (photo de profil) | ✅ |
| Routes debug `/debug-datenow`, `/debug-matching` | gated `if (kDebugMode)` dans `app_router.dart` (lignes 188–199) — absentes du binaire release | ✅ |
| Tuile « Debug · DateNow » dans Réglages | gated `if (kDebugMode)` | ✅ |
| Overlay OBS en release | non monté en release (`!kDebugMode → child brut`) | ✅ |
| `AppLogger` | gated `if (!kDebugMode) return;` → aucun log en release | ✅ |
| Token Agora dans les logs | seuls `len=…` + `uid=…` + `expiresAt=…` exposés, **jamais la chaîne du token** (`agora_token_repository.dart` lignes 77–81) | ✅ |
| `AGORA_APP_CERTIFICATE` côté Flutter | absent de `lib/` (vérifié par `release_safety_test.dart`) | ✅ |

**⚠ Warning 1.1 — bundle ID Debug.** Le `BUILD_MOBILE_CHECKLIST.md`
affirme que tous les configs (Debug / Profile / Release) sont sur
`com.datenow.app`. **C'est inexact** : la config Debug est encore sur
`com.guims.datenow`. Sans impact sur TestFlight (seul le binaire Release
est uploadé), mais à uniformiser dans le pbxproj quand l'occasion se
présente (1 ligne à éditer, sans risque).

**⚠ Warning 1.2 — version.** `pubspec.yaml = 0.1.0+2`. TestFlight refuse
un build dont le `+build` existe déjà. Avant le prochain upload :
incrémenter (ex. `0.1.0+3`).

---

## 2. Audit secrets / env

| Vérification | Résultat | OK |
|--------------|----------|----|
| `.env` contient uniquement `SUPABASE_URL` + `SUPABASE_ANON_KEY` + `AGORA_APP_ID` + `APP_ENV` | ✅ confirmé — aucun autre token | ✅ |
| `AGORA_APP_CERTIFICATE` côté serveur uniquement | mentionné uniquement comme commentaire « must be stored via `supabase secrets set` » dans `.env` et `.env.example`, **jamais en valeur** | ✅ |
| Service-role Supabase côté Flutter | absent (`SUPABASE_SERVICE` introuvable dans `lib/`) | ✅ |
| `.env` gitignored | oui (`.gitignore` ligne 48 : `.env`) | ✅ |
| `.env` jamais committé | `git log --all -- .env` → vide ; `git ls-files .env` → vide | ✅ |
| `.env.example` sans secret réel | toutes les valeurs vides, structure pédagogique | ✅ |
| GitHub | rien à vérifier ici (le `.env` n'a jamais été poussé) | ✅ |

**À garder en tête :** la rotation de la `SUPABASE_ANON_KEY` actuelle
n'est pas urgente (clé publique RLS-protégée), mais si elle a fuité dans
un canal extérieur, la régénérer via Supabase Dashboard.

---

## 3. Audit Supabase (schéma, RLS, Realtime)

**project-ref attendu :** `acastkbndpygowltemzp` (confirmé dans `.env`).

### Tables présentes (`supabase/migrations/`)

| Table | Migration | Présente |
|-------|-----------|----------|
| `profiles` | `20260513120000_initial_schema.sql` | ✅ |
| `user_preferences` | idem | ✅ |
| `user_photos` | idem | ✅ |
| `weekly_suggestions` | idem | ✅ |
| `matches` | idem + recréation auto-contenue dans `20260517130000_reveals.sql` | ✅ |
| `calls` | idem + extension `20260514130000_calls_session_status.sql` (status / channel_name / ended_by) + `20260517150000_presence.sql` (caller_ready / callee_ready) | ✅ |
| `blocked_users` / `reports` / `subscriptions` / `user_settings` | initial_schema | ✅ |
| `conversations` / `messages` | `20260513120400_messaging.sql` | ✅ |
| `matchmaking_queue` (+ heartbeat_at) | `20260517120000_matchmaking.sql` + `20260517140000_session_hygiene.sql` | ✅ |
| `reveals` | `20260517130000_reveals.sql` | ✅ |
| `user_presence` | `20260517150000_presence.sql` | ✅ |
| `call_participants` | **non créée** (jamais référencée) — pas nécessaire, le modèle 1-1 stocke caller_id/callee_id directement | ✅ (non-requis) |

### RLS

`ENABLE ROW LEVEL SECURITY` confirmé sur : `profiles`, `user_preferences`,
`user_photos`, `weekly_suggestions`, `matches`, `calls`, `blocked_users`,
`reports`, `subscriptions`, `user_settings`, `conversations`, `messages`,
`matchmaking_queue`, `reveals`, `user_presence`.

Policies clés :
- `calls_all_participant` — seul caller/callee lit/écrit la row ✅
- `reveals_modify_own` + `reveals_select_participant` — un user écrit
  uniquement sa propre décision, voit celle du peer ✅
- `matches_all_participant` — seuls les deux user_a/user_b ✅
- `conversations_participant_*` + `messages_participant_*` ✅
- `user_photos_all_owner` + `user_photos_select_matched` +
  `user_photos_conversation_select` — photos privées par défaut ✅

### Realtime (`supabase_realtime` publication)

| Table | Wired | Migration |
|-------|-------|-----------|
| `calls` | ✅ | `20260514130000_calls_session_status.sql` ligne 88 |
| `matchmaking_queue` | ✅ | `20260517120000_matchmaking.sql` ligne 48 |
| `reveals` | ✅ | `20260517130000_reveals.sql` ligne 60 |
| `user_presence` | ✅ | `20260517150000_presence.sql` ligne 67 |
| `conversations` | ✅ (+ `REPLICA IDENTITY FULL`) | `20260513120400_messaging.sql` |
| `messages` | ✅ (+ `REPLICA IDENTITY FULL`) | idem |

### Fonctions critiques

| Fonction | Garantie | OK |
|----------|----------|----|
| `claim_match(peer_id)` | SECURITY DEFINER, atomic : retourne le call existant pour la paire OU crée + dérive `channel_name = 'dn_' \|\| id` + supprime les deux de la queue. **Impossible d'avoir deux calls actifs pour une paire** par construction. | ✅ |
| `mark_call_ready(p_call_id)` | UPDATE caller_ready ou callee_ready selon `auth.uid()` — un client ne peut pas marquer son peer ready. | ✅ |
| `queue_heartbeat()` + `active_queue_peers()` | heartbeat serveur + filtre 30 s côté serveur → app crashée/fermée ignorée automatiquement. | ✅ |
| `set_presence(status)` + `active_profiles_count()` | présence + comptage actifs (<60 s) côté serveur. | ✅ |

### Reste à faire avant TestFlight (action manuelle)

- ⏸ **NOT RUN** : `supabase db push` sur le project-ref `acastkbndpygowltemzp` doit dire `up to date`.
- ⏸ **NOT RUN** : `supabase functions list` doit montrer `generate-agora-token`.
- ⏸ **NOT RUN** : `supabase secrets list` doit montrer `AGORA_APP_ID` **et** `AGORA_APP_CERTIFICATE`.

---

## 4. Audit Agora

| Vérification | Résultat | OK |
|--------------|----------|----|
| `AGORA_APP_ID` côté Flutter | lu depuis `.env` via `core/config/env.dart:45` | ✅ |
| `AGORA_APP_CERTIFICATE` côté Flutter | **absent** de `lib/` (test `release_safety_test.dart` vert) | ✅ |
| Edge Function `generate-agora-token` | présente (`supabase/functions/generate-agora-token/index.ts`) | ✅ |
| Token signé côté serveur, TTL 15 min | `TOKEN_TTL_SECONDS = 15 * 60` (couvre les 5 min de call + marge reconnect) | ✅ |
| Vérif que l'utilisateur participe au call avant signature | lignes 100–113 : SELECT `calls` + `caller_id/callee_id = userId` → 403 sinon | ✅ |
| Vérif `channel_name` match `calls.channel_name` | ligne 114 : 403 `channel_mismatch` sinon | ✅ |
| Vérif call non-`ended` | ligne 117 : 410 `call_already_ended` sinon | ✅ |
| UID Agora stable par user | `uidForUser(userId) = userId.hashCode & 0x7FFFFFFF` (`agora_token_repository.dart:50`) — même valeur à chaque appel | ✅ |
| Channel name identique aux deux peers | dérivé serveur dans `claim_match` : `'dn_' \|\| fresh.id` — unique row → unique channel | ✅ |
| Token complet jamais loggé côté serveur | logs : `tokenLen=${token.length}` seulement | ✅ |
| Token complet jamais loggé côté client | logs : `len=${token.token.length} uid=… expiresAt=…` seulement (`agora_token_repository.dart:78`) | ✅ |
| Token absent du `AgoraTokenDebugInfo` (Debug screen) | confirmé par `release_safety_test.dart` | ✅ |
| Permissions caméra + micro demandées AVANT `AgoraClient.initialize()` | `agora_call_view.dart:99` | ✅ |
| Refus permission → message clair, pas de crash | `_ErrorPanel` mappe `permission_denied` à un message FR non-technique | ✅ |
| Échec token → message clair, pas de crash | `_ErrorPanel` mappe `token_unavailable` / `token_failed` | ✅ |

**Reste à faire avant TestFlight (action manuelle) :**

- ⏸ **NOT RUN** : tester l'Edge Function en live :
  ```bash
  # Participant valide → 200 + JSON token
  curl -i -X POST \
    "$SUPABASE_URL/functions/v1/generate-agora-token" \
    -H "Authorization: Bearer <jwt-d-un-participant>" \
    -H "Content-Type: application/json" \
    -d '{"call_id":"<id>","channel_name":"dn_<id>","uid":12345}'

  # Non-participant → 403 / mauvais channel → 403 channel_mismatch
  ```

---

## 5. Test réel 2 iPhones — scénario nominal

**Prérequis G1–G7 :** voir `docs/TEST_PROTOCOL_MVP.md` §Prérequis généraux.

### Étapes (binaire **debug** installé via Xcode, ou **TestFlight** une fois uploadé)

1. ☐ Compte A se connecte (inscription si premier lancement → vérif email Supabase si activée).
2. ☐ Compte B se connecte.
3. ☐ Vérifier compatibilité ≥ 75 % (Debug → carte Matching, ligne du peer).
4. ☐ A : « Trouver un date » (Home → CTA).
5. ☐ B : « Trouver un date » dans les ~10 s.
6. ☐ Les deux entrent en queue (`matchmaking_queue`).
7. ☐ Un seul `calls` créé pour la paire (vérif Debug → carte Call sur les 2 téléphones).
8. ☐ `call_id` identique des deux côtés.
9. ☐ `channel_name` identique des deux côtés (`dn_<call_id>`).
10. ☐ Les deux arrivent dans la même visio Agora (peer visible).

### À vérifier *en plus*

- ☐ Aucun double-call (vérifier `supabase/tests/flow_checks.sql` final : 0 ligne).
- ☐ Aucun blocage queue (les deux rows ont disparu de `matchmaking_queue`).
- ☐ Aucun navigateur externe lancé — tout reste in-app.
- ☐ Aucun écran debug visible si build TestFlight (release).

**Priorité :** 🔴 Bloquant

---

## 6. Test visio / caméra / micro / flou

| Vérification | Attendu | OK |
|--------------|---------|----|
| Permission caméra demandée au 1ᵉʳ date | dialogue iOS avec texte `NSCameraUsageDescription` | ☐ |
| Permission micro demandée au 1ᵉʳ date | dialogue iOS avec texte `NSMicrophoneUsageDescription` | ☐ |
| Caméra fonctionnelle (peer voit A) | flux vidéo arrive côté B | ☐ |
| Micro fonctionnel (peer entend A) | flux audio arrive côté B | ☐ |
| Visio in-app (jamais d'ouverture navigateur) | reste dans le binaire | ☐ |
| iPhone A voit iPhone B | `onUserJoined` + `onFirstRemoteVideoFrame` loggés | ☐ |
| iPhone B voit iPhone A | idem | ☐ |
| Même channel Agora | `Debug → carte Call → channel_name` identique | ☐ |
| Pas d'écran noir au reveal | la phase `_PreCall.waitingPeer → joining → live` lisse la transition | ☐ |
| Pas de crash | _ | ☐ |
| Bouton « Terminer le date » fonctionnel | flip `status = ended` → l'autre côté tear-down via Realtime | ☐ |

### Flou caméra — point d'attention iOS

Implémenté dans `agora_call_view.dart:362–369` :

```dart
Positioned.fill(
  child: ClipRect(
    child: BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
      child: const SizedBox.expand(),
    ),
  ),
),
```

- ☐ Vérifier sur **iPhone physique** que le flou est **réellement visible**
  sur le rendu Agora (les `PlatformView` Agora peuvent ignorer `BackdropFilter`
  selon la version iOS / Flutter).
- ☐ Si le flou n'est pas visible : fallback documenté = utiliser un
  `ImageFilter.blur` via `BackdropFilter` au-dessus d'un `AgoraVideoViewer`
  encapsulé dans un `RepaintBoundary`, ou activer le blur côté Agora SDK
  via `setBeautyEffectOptions`.
- ☐ Vérifier que la légende « Caméra floutée jusqu'à la fin du date »
  s'affiche (anti-méprise « caméra cassée »).

**Priorité :** 🔴 Bloquant. Le flou est l'identité produit DateNow.

---

## 7. Test timer / fin d'appel

| Vérification | Attendu | OK |
|--------------|---------|----|
| Timer basé sur `started_at` serveur | `CallScreen._start = session.startedAt` (`call_screen.dart:141`) | ☐ |
| Timer cohérent sur les 2 téléphones | écart < 2 s (dérivé d'une même valeur serveur) | ☐ |
| Fin automatique à 5 min | `AppConfig.maxCallDuration = Duration(minutes: 5)` → `_endCall()` | ☐ |
| Sortie propre du channel Agora | `client.release()` dans `AgoraCallView.dispose()` | ☐ |
| Navigation auto vers `PostCallScreen` | `pushReplacementNamed(AppRoute.postCall.name)` après `_endCall` | ☐ |
| Si A coupe : B reçoit la fin via Realtime | `endedByPeer(selfId)` → `_endCall(remote: true)` | ☐ |

**Priorité :** 🔴 Bloquant.

---

## 8. Test reveal / match / chat

| Vérification | Attendu | OK |
|--------------|---------|----|
| A révèle seul → attente | `_Stage.waiting`, spinner | ☐ |
| Timeout d'attente à 2 min | `_revealTimedOut = true`, propose « Continuer à attendre » / « Passer » | ☐ |
| A et B révèlent → match permanent | row `matches` créée (UNIQUE pair) | ☐ |
| Photo/profil débloqué (`_PhotoReveal`) | **⚠ voir bug majeur ci-dessous** | ☐ |
| Conversation/chat créé | `messaging_repository.ensureConversation` → row `conversations` | ☐ |
| A révèle et B passe → pas de match | reveal row de B avec `revealed=false` → outcome `declined` | ☐ |
| Pas de doublon de match | `UNIQUE(user_a_id, user_b_id)` + ordered pair | ☐ |
| RLS : seuls A et B voient leur conversation | `conversations_participant_select` | ☐ |

### 🟠 Bug majeur connu — photo affichée au reveal

**Fichier :** `lib/features/post_call/presentation/post_call_screen.dart:66–78`

```dart
Future<void> _loadPeerPhoto() async {
  // For MVP demo we don't ship real candidate photos. Reuse the current
  // user's own primary photo as the stand-in so the reveal effect is
  // demoable end-to-end. Real builds will pull the matched profile's
  // primary photo from the repository.
  final ownProfile = ref.read(currentProfileProvider).asData?.value;
  final ownUrl = ownProfile?.primaryPhotoUrl;
  ...
}
```

**Conséquence concrète :** au reveal, **A voit sa propre photo** affichée
comme celle de B, et vice-versa. C'est cohérent dans une démo solo, mais
**trompeur pour un test client réel** : les testeurs vont voir leur propre
visage à la place du peer et croire à un bug.

**Fix proposé (1 méthode, ~10 lignes, aucune logique métier touchée) :**
remplacer `currentProfileProvider` par
`profileRepositoryProvider.getProfile(match.candidate.userId)` puis
`getPhotoBytes(peer.primaryPhotoUrl)`. La RLS `user_photos_select_matched`
+ `user_photos_conversation_select` autorise déjà la lecture côté peer
une fois le match écrit, donc la requête passera.

**Priorité :** 🔴 Bloquant pour un test client (faux positif visuel
inacceptable). Pour un test interne « tech » : 🟠 majeur, contournable
en briefant les testeurs.

---

## 9. Test cas d'échec

| Scénario | Comportement attendu | OK |
|----------|----------------------|----|
| A lance recherche, B absent | A reste sur écran « recherche » sans bloquer ; bouton Annuler dispo | ☐ |
| A quitte la recherche | `leaveQueue` appelé en best-effort dans `dispose()` | ☐ |
| App fermée pendant la queue | heartbeat s'arrête → row stale après 30 s → exclue par `active_queue_peers()` | ☐ |
| Call créé mais peer ne rejoint pas | `_peerAbsentTimer = 45 s` côté Agora → fin propre | ☐ |
| Peer ready timeout pré-call | `_peerReadyTimeout = 15 s` → join sans attendre, ne bloque jamais | ☐ |
| Perte réseau courte | `onConnectionStateChanged → reconnecting` + banner « Reconnexion en cours… » | ☐ |
| Retour arrière-plan iOS | l'app continue d'émettre/recevoir Agora tant que iOS ne tue pas le process ; le timer continue (serveur) | ☐ |
| Permission caméra refusée | `_ErrorPanel` « Caméra et micro nécessaires » + bouton retour ; pas de crash | ☐ |
| Permission micro refusée | idem | ☐ |
| Token Agora indisponible (edge function KO) | `_ErrorPanel` « Connexion sécurisée indisponible » ; pas de crash | ☐ |
| Supabase lent / Realtime retardé | `markReady` peut échouer mais ne bloque pas le join ; safety valve 15 s prend le relais | ☐ |
| `claim_match` race condition | côté serveur : retourne le call existant si déjà créé pour la paire → pas de double | ✅ (statique) |

**Critère global :** l'app ne reste **jamais bloquée**. Tous les chemins
d'erreur ont une issue claire (Retour, Annuler, Réessayer).

**Priorité :** 🔴 Bloquant. Aucun scénario ne doit produire un freeze
ou un crash.

---

## 10. Vérifications automatisées (résultats)

| Commande | Statut | Détails |
|----------|--------|---------|
| `flutter analyze` | ✅ PASS | 0 erreur, 14 `info` lint cosmétiques (prefer_const_constructors, use_super_parameters) — non-bloquants |
| `flutter test` | ✅ PASS | **33/33 tests verts** — flow_simulation, release_safety, matching_service, validators, age helpers, locale resolver |
| `flutter build ios --release --no-codesign` | ✅ PASS | `Built build/ios/iphoneos/Runner.app (129.4MB)` — bundle `com.datenow.app`, 237,9 s |
| `bash scripts/smoke_check.sh` | ✅ PASS (à re-exécuter avant chaque session) | 7/7 checks statiques |
| `bash scripts/pre_real_device_test.sh` | non relancé | Couvre analyze + test + smoke en une commande |

### Lints `info` à nettoyer un jour (non-bloquant MVP)

```
prefer_const_constructors × 12
use_super_parameters × 1
```

---

## 11. Bugs / actions restantes avant TestFlight client

### 🔴 Bloquants (doivent passer avant l'envoi du lien au client)

1. **Photo du peer au reveal** (§8) — corriger `_loadPeerPhoto()` pour
   charger la photo de `match.candidate.userId`, pas celle de l'utilisateur
   courant. Sans ce fix, le test client est faussé visuellement.
2. **Test 2-iPhones du scénario nominal** (§5) effectué de bout en bout
   avec succès (scénarios 1, 5, 6, 9 de `TEST_PROTOCOL_MVP.md`).
3. **Visibilité réelle du flou caméra sur iPhone physique** (§6).
   Si non visible : appliquer un des fallbacks documentés.
4. **Edge Function `generate-agora-token` déployée + secrets `AGORA_APP_ID`
   + `AGORA_APP_CERTIFICATE` configurés sur Supabase remote** (§3, §4) —
   à confirmer via `supabase functions list` + `supabase secrets list`.
5. **Incrémenter `pubspec.yaml` version** à `0.1.0+3` (ou plus) avant
   l'archive Xcode (§1).

### 🟠 Majeurs (à corriger rapidement, n'empêchent pas une démo encadrée)

- Uniformiser le bundle ID **Debug** dans `project.pbxproj` ligne 699 :
  `com.guims.datenow` → `com.datenow.app` (cohérence).
- Mettre à jour `docs/BUILD_MOBILE_CHECKLIST.md` qui prétend à tort que
  les 3 configs sont déjà sur `com.datenow.app`.
- Logo / icône app — vérifier que l'`AppIcon.appiconset` est bien
  remplacé (non vérifié dans cet audit, mais Apple le contrôle en revue
  Beta).

### 🟢 Acceptables MVP (à noter, à corriger plus tard)

- 14 lints `info` (`prefer_const_constructors`, `use_super_parameters`) —
  purement cosmétique, n'affecte pas l'exécution.
- Bundle ID `RunnerTests` = `com.guims.datenowTests` — pas d'impact prod.
- Pré-call : `markReady` peut échouer silencieusement et le join se fait
  quand même via la safety valve 15 s — c'est volontaire, à laisser tel
  quel pour le MVP.

---

## 12. Critères Go / No-Go MVP

| Critère | Statut |
|---------|--------|
| App compile iOS release | ✅ PASS — `Built Runner.app (129.4MB)` pour `com.datenow.app` |
| Aucun debug visible en release | ✅ (gated `kDebugMode` + test automatisé) |
| Connexion inscription/auth | ⏸ à valider 2 phones |
| Matching → claim_match → call unique | ✅ (statique : RPC atomic SECURITY DEFINER) — ⏸ à valider 2 phones |
| Visio Agora fonctionnelle | ⏸ à valider 2 phones |
| Caméra + micro fonctionnels | ⏸ à valider 2 phones |
| Flou visible ou fallback documenté | ⏸ à valider 2 phones |
| Reveal mutuel → match + chat | ✅ (statique) — ⚠ photo peer = bug §8 — ⏸ à valider 2 phones |
| Aucun crash bloquant | ⏸ à valider 2 phones |

```
┌──────────────────────────────────────────────────────────┐
│  Code & infra : 🟢 GO (statique vert)                    │
│  + corriger bug photo §8                                 │
│  + 2-iPhones smoke pass                                  │
│  + supabase functions/secrets confirmés                  │
│  + version pubspec incrémentée                           │
│      ───────────────────────────────────────             │
│                → GO TestFlight client                    │
└──────────────────────────────────────────────────────────┘
```

---

## Annexe — Commandes utiles

```bash
# Vérif statique automatisée
bash scripts/smoke_check.sh

# Suite Flutter
flutter analyze
flutter test
flutter build ios --release --no-codesign     # vérif build pure
flutter build ios --release                   # build signée (TestFlight)

# Supabase (côté infra)
supabase db push
supabase functions list
supabase secrets list

# Agora token live
curl -i -X POST "$SUPABASE_URL/functions/v1/generate-agora-token" \
  -H "Authorization: Bearer <jwt-d-un-participant>" \
  -H "Content-Type: application/json" \
  -d '{"call_id":"<id>","channel_name":"dn_<id>","uid":12345}'
```
