# Rapport de test technique simulé — DateNow

Test technique du flow **avant** le test réel sur 2 téléphones. Vérifie
comment le code réagit aux scénarios critiques, sans device physique.

- **Date d'exécution :** 2026-05-17
- **Commande globale :** `bash scripts/pre_real_device_test.sh`
- **Aucune logique métier modifiée** — uniquement des tests et scripts ajoutés.

## Synthèse

| # | Test | Statut |
|---|------|--------|
| 1 | Matching (score ≥ 75 %) | ✅ PASS (partie Dart) · ⏸ NOT RUN (partie SQL) |
| 2 | Anti double-claim | ⏸ NOT RUN (atomicité serveur) |
| 3 | Heartbeat queue | ⏸ NOT RUN (RPC + contexte auth) |
| 4 | Token Agora | ⏸ NOT RUN (Edge Function déployée requise) |
| 5 | Pré-call (handshake ready) | ✅ PASS |
| 6 | Timer serveur | ✅ PASS |
| 7 | Reveal (pending/mutual/declined) | ✅ PASS |
| 8 | Debug / release | ✅ PASS |
| 9 | Smoke global | ✅ PASS |

**33 tests Flutter passés, 0 échec. `flutter analyze` : 0 erreur.**
Les `NOT RUN` ne sont **pas** des échecs : ce sont des vérifications qui
exigent une base de données / une Edge Function déployée / deux clients
réels — non atteignables depuis `flutter test`. Chacune a un moyen de
contrôle dédié (script SQL, procédure curl, run 2 téléphones).

---

## 1. Test Matching

- **Statut :** ✅ PASS (score) · ⏸ NOT RUN (effets serveur)
- **Commande :** `flutter test test/flow_simulation_test.dart`
- **Résultat observé :**
  - Deux profils fortement compatibles → score **≥ 75 %** : PASS.
  - Score symétrique A→B = B→A : PASS.
  - `claim_match` crée une seule row `calls`, même `channel_name` pour les
    deux, retrait de `matchmaking_queue` → **NOT RUN** : RPC SQL avec
    `auth.uid()`, non exécutable en `flutter test`.
- **Contrôle de la partie serveur :** `supabase/tests/flow_checks.sql`
  (vérifie que `claim_match` existe + sonde « pas de call actif en
  double ») et le scénario 2 téléphones (`docs/TEST_PROTOCOL_MVP.md` §1).
- **Correction si FAIL :** revoir les poids de `MatchingService` si le
  score passe sous 75 % pour des profils censés matcher.

## 2. Test anti double-claim

- **Statut :** ⏸ NOT RUN
- **Pourquoi :** l'atomicité de `claim_match` (A claim B et B claim A
  quasi simultanément → un seul call, même row pour les deux) se joue
  dans la transaction Postgres `SECURITY DEFINER`. Non simulable sans
  deux sessions authentifiées concurrentes.
- **Comment vérifier :** la fonction `claim_match` rouvre un call existant
  pour la paire (`SELECT … WHERE pair ORDER BY started_at LIMIT 1`) avant
  d'en créer un — garantie « une paire = un call ». À confirmer par :
  1. la sonde finale de `supabase/tests/flow_checks.sql` (0 ligne = OK) ;
  2. le run 2 téléphones (`docs/TEST_PROTOCOL_MVP.md` §1) : `channel_name`
     identique des deux côtés.
- **Correction si FAIL :** si deux calls actifs apparaissent pour une
  paire, ajouter une contrainte d'unicité partielle sur `calls`.

## 3. Test heartbeat queue

- **Statut :** ⏸ NOT RUN
- **Pourquoi :** `active_queue_peers()` filtre `heartbeat_at > now() - 30 s`
  côté serveur et lit `auth.uid()` — non exécutable hors session auth.
- **Comment vérifier :** `supabase/tests/flow_checks.sql` confirme que
  `active_queue_peers()`, `queue_heartbeat()` et la colonne
  `matchmaking_queue.heartbeat_at` existent. Le comportement (peer frais
  visible, peer périmé ignoré) est couvert par `docs/TEST_PROTOCOL_MVP.md`
  §3 (abandon recherche).
- **Correction si FAIL :** réappliquer la migration
  `20260517140000_session_hygiene.sql`.

## 4. Test token Agora

- **Statut :** ⏸ NOT RUN
- **Pourquoi :** nécessite l'Edge Function `generate-agora-token`
  **déployée** + un JWT utilisateur valide.
- **Comment vérifier (procédure manuelle) :**
  ```bash
  # participant valide → 200 + {token, appId, uid, channelName, expiresAt}
  curl -i -X POST \
    "$SUPABASE_URL/functions/v1/generate-agora-token" \
    -H "Authorization: Bearer <jwt-d-un-participant>" \
    -H "Content-Type: application/json" \
    -d '{"call_id":"<id>","channel_name":"dn_<id>","uid":12345}'

  # non-participant → 403
  # mauvais channel_name → 403 channel_mismatch
  ```
- **Garde-fous déjà vérifiés en statique (test 8) :** le token complet
  n'est jamais loggé ni stocké dans `AgoraTokenDebugInfo`, et
  `AGORA_APP_CERTIFICATE` est absent de `lib/`.
- **Correction si FAIL :** `supabase functions deploy generate-agora-token`
  + `supabase secrets set AGORA_APP_ID=… AGORA_APP_CERTIFICATE=…`.

## 5. Test pré-call

- **Statut :** ✅ PASS
- **Commande :** `flutter test test/flow_simulation_test.dart`
- **Résultat observé :**
  - `CallSessionRow.bothReady` reste `false` tant que `caller_ready` **et**
    `callee_ready` ne sont pas tous deux vrais → Agora ne monte pas avant
    que les deux soient prêts : PASS.
  - `peerReady()` résout bien le participant opposé selon le point de vue :
    PASS.
- **Note :** la transition d'écran `waitingPeer → joining → live` vit dans
  `_CallScreenState` (état de widget) — testée manuellement (scénario 5
  du run 2 téléphones). Le **verrou** logique (`bothReady`) est, lui,
  couvert automatiquement.
- **Correction si FAIL :** vérifier le parsing `caller_ready`/`callee_ready`
  dans `CallSessionRow.fromJson`.

## 6. Test timer serveur

- **Statut :** ✅ PASS
- **Commande :** `flutter test test/flow_simulation_test.dart`
- **Résultat observé :**
  - `started_at` parsé en instant **UTC** : PASS.
  - Temps restant = `maxCallDuration - elapsed(started_at)` (≈ 4 min pour
    un call créé il y a 60 s) : PASS.
  - Un rejoin re-lit le **même** `started_at` → même temps restant :
    coherence cross-device et cross-rejoin confirmée : PASS.
- **Correction si FAIL :** s'assurer que `started_at` est renseigné par le
  serveur sur chaque row `calls`.

## 7. Test reveal

- **Statut :** ✅ PASS
- **Commande :** `flutter test test/flow_simulation_test.dart`
- **Résultat observé :**
  - A révèle seul → `pending` : PASS.
  - A et B révèlent → `mutual` : PASS.
  - A révèle, B passe → `declined` : PASS.
  - Seul `mutual` débloque un match permanent (`pending`/`declined` ne
    sont jamais `mutual`) : PASS.
- **Anti-doublon :** `createMatch` fait un `upsert` sur
  `UNIQUE(user_a_id,user_b_id)` avec paire ordonnée — un second appel
  (peer simultané) ne duplique pas. Contrainte vérifiée structurellement
  par `flow_checks.sql`.
- **Correction si FAIL :** vérifier la logique `outcomeFor` (un
  `revealed=false` = pass explicite → `declined`).

## 8. Test debug / release

- **Statut :** ✅ PASS
- **Commande :** `flutter test test/release_safety_test.dart`
- **Résultat observé :**
  - `/debug-datenow` et `/debug-matching` sont sous `if (kDebugMode)` dans
    le routeur → non enregistrées en release : PASS.
  - `AppLogger` gated `if (!kDebugMode) return;` → aucun log en release :
    PASS.
  - Aucune occurrence de `AGORA_APP_CERTIFICATE` dans `lib/` : PASS.
  - `AgoraTokenDebugInfo` ne porte pas la chaîne du token : PASS.
- **Correction si FAIL :** remettre le `if (kDebugMode)` manquant.

## 9. Test smoke global

- **Statut :** ✅ PASS
- **Commande :** `bash scripts/pre_real_device_test.sh`
- **Résultat observé :**
  - `scripts/smoke_check.sh` : **7/7** checks statiques OK.
  - `flutter analyze` : **0 erreur** (15 `info` lint pré-existants tolérés).
  - `flutter test` : **33/33** tests passés.
- **Build iOS :** ✅ `flutter build ios --debug --no-codesign` →
  `✓ Built …Runner.app` (bundle `com.datenow.app`).
- **Build Android :** ⏸ NOT RUN — Android SDK absent de cette machine
  (`flutter doctor` : « Unable to locate Android SDK »). À lancer sur un
  poste équipé : `flutter build apk --debug`.

---

## Conclusion

Tout ce qui est vérifiable sans device ni base de données réagit
**correctement** : matching, handshake pré-call, timer serveur, reveal et
garde-fous release sont couverts par des tests automatisés verts.

Restent à valider **avant le test réel** (non bloquant côté code, mais
obligatoire côté infra) :
1. `supabase/tests/flow_checks.sql` exécuté dans l'éditeur Supabase — tout PASS.
2. Edge Function `generate-agora-token` déployée + secrets Agora — test §4.
3. `flutter build apk --debug` sur un poste avec Android SDK.
4. Scénario 2 téléphones — `docs/SMOKE_TEST_FINAL.md` §3.
