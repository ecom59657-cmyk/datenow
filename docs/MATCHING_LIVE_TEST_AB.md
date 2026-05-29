# Test live « Trouver un date » — protocole A/B (engine v1 actif)

> **Objectif** : valider entre **2 iPhones réels** que le bouton
> « Trouver un date » fonctionne de bout en bout avec le moteur
> **legacy v1** (`find_best_live_candidate_v1` + `claim_match`) **avant
> toute bascule v2 runtime**.

Tag de logs à grep : **`[MATCHING V1]`** (logger renommé pour ce test).

---

## 1. Prérequis

### Comptes
- **Compte A** et **Compte B** déjà inscrits sur DateNow (Apple, Google
  ou OTP) avec **profil complet** + **au moins 1 photo** + onboarding
  terminé. Sans ça, `_onFindDate` court-circuite avant même de pousser
  `/matching` (gates photo / quota / profile sur `home_screen.dart:162`).
- A et B doivent être **mutuellement compatibles** côté préférences :
  - genre / orientation : A.gender ∈ B.seeking_genders **et** B.gender
    ∈ A.seeking_genders ;
  - âge : A.age ∈ [B.seeking_age_min, B.seeking_age_max] et symétrique ;
  - distance : `ST_DistanceSphere(A.location, B.location) <
    LEAST(A.max_distance_km, B.max_distance_km) * 1000`.
- Sinon, `find_best_live_candidate_v1` rejettera le pair avec
  `rejection_reason` explicite dans les logs.

### Appareils
- **Idéal** : 2 iPhones (un par compte, sur TestFlight build 0.1.0+28).
- **Acceptable** : 1 iPhone (TestFlight) + 1 simulator macOS (sur la
  même build debug).
- **Pas acceptable** : 2 simulateurs uniquement (Realtime Supabase peut
  être instable sur 2 simulateurs en parallèle ; certaines permissions
  bgservice diffèrent).

### Réseau
- Les 2 appareils doivent voir l'Internet en même temps.
- Si l'un des deux est sur réseau cellulaire et l'autre en Wi-Fi : OK
  (la latence diff peut révéler des bugs de race).
- Pas de VPN sur l'un des deux (peut casser Supabase Realtime).

### Position GPS
- Si les comptes test ont une `location` réelle éloignée :
  - soit ajuster `max_distance_km` dans la table `user_preferences`
    (via Supabase Studio) à une valeur élevée (ex. `500`) pour
    contourner le filtre distance ;
  - soit utiliser **Xcode → Debug → Simulate Location** pour aligner
    les deux iPhones sur la même ville.
- Sinon les deux comptes seront filtrés par la gate distance avant
  même le scoring.

---

## 2. Setup monitoring des logs

### iPhone réel (TestFlight ou Xcode)
```bash
# Mac connecté à l'iPhone via câble + iPhone déverrouillé
# Console.app sur Mac : filtrer par 'datenow' ou par '[MATCHING V1]'
```

ou via Xcode :
1. Window → Devices and Simulators
2. Sélectionner l'iPhone → "Open Console"
3. Filter : `[MATCHING V1]`

### Simulator
```bash
xcrun simctl spawn booted log stream --predicate \
  'eventMessage CONTAINS "[MATCHING V1]"'
```

Tous les logs critiques émis par ce flow ont le préfixe
`[MATCHING V1]` (Repository + Screen + Realtime callbacks).

---

## 3. Scénarios de test

### S1 — Solo (sanity check, doit signaler "personne autour")

| Étape | Acteur | Action | Log attendu | OK ? |
|---|---|---|---|---|
| 1 | A | Ouvrir l'app, taper « Trouver un date » | `[MATCHING V1] Match flow started — entering matchmaking queue` | |
| 2 | A | (auto) joinQueue + heartbeat | `[MATCHING V1] joinQueue user=<A.id>` puis `[MATCHING V1] joined queue ok — clock started at <ISO>` | |
| 3 | A | (auto) premier poll après ~2.5 s | `[MATCHING V1] find_best_live_candidate_v1 → no match — reason=queue_empty eligible=0 queue=1` | |
| 4 | A | Laisser tourner 30 s | Polls répétés toutes les 2.5 s avec la même reason | |
| 5 | A | Taper "annuler" / quitter | `[MATCHING V1] queue heartbeat failed (will retry):` (au pire) puis sortie clean | |

**Verdict S1** : l'engine répond proprement à un seul user en file.
Pas de match attendu, pas d'exception.

---

### S2 — Paire simultanée (le test critique)

> A et B tapent « Trouver un date » dans une fenêtre de **5 secondes**.

| Étape | Acteur | Action | Log attendu (A) | Log attendu (B) |
|---|---|---|---|---|
| 1 | A | Tap « Trouver un date » | `Match flow started`, `joinQueue user=<A>`, `joined queue ok` | — |
| 2 | B (≤ 5 s après) | Tap « Trouver un date » | (pendant ce temps A poll → `queue=1 eligible=0`) | `Match flow started`, `joinQueue user=<B>`, `joined queue ok` |
| 3 | (auto) | Le poll de A OU B exécute `find_best_live_candidate_v1` | l'un des deux loggue : `find_best_live_candidate_v1 → <peer> score=X/100 dist=Ym (d=… i=… a=… f=…) eligible=1 queue=2` | (l'autre n'a peut-être pas encore poll) |
| 4 | (auto) | Le winner appelle `claim_match(peer_id)` | `claimMatch peer=<peer>` puis `claimMatch ok — callId=<id> channel=dn_<id>` | — |
| 5 | (auto) | Realtime stream `calls` table broadcast la row | (le winner émet le log `Matched! peer=… waited=<ms>`) | **`Matched! peer=… waited=<ms>`** (via `watchMyActiveCall` Realtime callback) |
| 6 | A et B | (auto, 1.6 s plus tard) | `Navigating to CallScreen — peer=<…>` | `Navigating to CallScreen — peer=<…>` |
| 7 | A et B | CallScreen s'affiche, Agora se connecte | logs `[CallSession] open meUserId=… peer=…` puis `[CallSession] fetched existing call …` | idem mais `fetched existing call` pour le second arrivé |

**Verdict S2** : les 2 iPhones convergent vers la **même calls.id** + le
même `channel_name` + arrivent sur la CallScreen ensemble. La vidéo
Agora doit s'établir (déjà testé OK sur le flow Discover).

**Indicateurs de succès** :
- ✅ `Matched!` apparaît sur **les deux** appareils dans une fenêtre de
  < 3 s entre A et B
- ✅ `waited=<ms>` < 5000 ms côté chacun (= < 5 s en queue)
- ✅ même `session=<id>` côté A et B
- ✅ CallScreen ouvert, vidéo Agora qui se connecte

**Indicateurs d'échec** :
- ❌ Un seul des deux loggue `Matched!` → race / Realtime cassée
- ❌ `claimMatch` jette `peer_already_taken` → 2 polls concurrents ont
  ciblé le même peer (devrait être impossible côté RPC mais à vérifier)
- ❌ `find_best_live_candidate_v1 → no match` après > 30 s alors que les
  2 sont en queue → le scoring rejette le pair (loguer la
  `rejection_reason`)
- ❌ Realtime pas reçu (`watchMyActiveCall` n'émet jamais) côté le user
  passif → le Realtime channel calls n'a pas réveillé son client

---

### S3 — Paire séquentielle (timing décalé > 30 s)

> A enters → B enters seulement après 30 s

| Étape | Acteur | Action | Log attendu |
|---|---|---|---|
| 1 | A | Tap « Trouver un date » | join + premier poll `queue=1` |
| 2 | A | Attend en file 30 s | polls répétés `queue=1` (tant que B n'est pas là) |
| 3 | B | Tap « Trouver un date » | join, `queue=2` au prochain poll |
| 4 | A et B | (auto) un des deux poll trouve le pair | `Matched!` côté winner + Realtime côté l'autre |

**Vérification supplémentaire** : `waited=<ms>` côté A doit refléter
les 30 s d'attente (ex. ~32000 ms). Côté B : < 5 s.

---

## 4. Format de rapport (à me retourner)

Pour chaque scénario testé, copie-colle simplement :

```
Scénario : S1 / S2 / S3
Date / heure du test :
Comptes : A=<uuid court>, B=<uuid court>
Préférences compatibles ? oui / non
Position GPS : alignées / éloignées de Xkm

Verdict : succès / échec partiel / échec total

Logs A :
<paste les lignes [MATCHING V1] de l'iPhone A, du tap jusqu'au CallScreen>

Logs B :
<idem côté B>

Anomalies observées :
- (libre)
```

---

## 5. Diagnostic des échecs courants

| Symptôme | Cause probable | Vérification |
|---|---|---|
| `joinQueue failed` | RLS / row déjà existante / network | Logs serveur Supabase + `SELECT * FROM matchmaking_queue` |
| `find_best_live_candidate_v1 → no match — reason=age_mismatch` | A et B incompatibles côté préférences | Comparer `user_preferences` des deux |
| `reason=distance_too_far` | `max_distance_km` trop petit | Augmenter manuellement dans `user_preferences` |
| `reason=blocked` | Un des deux a bloqué l'autre | `SELECT * FROM blocked_users WHERE …` |
| Pas de Realtime sur le user passif | `calls` table pas dans `supabase_realtime` publication | `SELECT tablename FROM pg_publication_tables WHERE pubname='supabase_realtime'` doit inclure `calls` |
| `Matched!` côté A jamais côté B | Le Realtime stream s'est désabonné | Logs Supabase Realtime + voir si `watchMyActiveCall` a logué une erreur |
| `claimMatch` jette `peer_already_taken` | Race entre deux peers visant la même cible | Devrait être impossible (RPC fait DELETE atomique). Bug à investiguer si reproduit. |

---

## 6. Décision après test

| Résultat S2 (paire simultanée) | Décision |
|---|---|
| ✅ Succès clean côté A **et** B, < 5 s, même call.id | La v1 fonctionne. La bascule v2 devient un **upgrade progressif non urgent**. On enchaîne sur les Phases 1-6 du plan v2 à ton rythme. |
| ⚠️ Succès côté A seulement (Realtime cassé côté B) | Bug Realtime sur `watchMyActiveCall` à corriger en priorité avant toute bascule. La v2 a le même pattern Realtime → ne corrige pas magiquement. |
| ❌ Aucun match trouvé alors que A et B sont compatibles | Bug dans `find_best_live_candidate_v1` ou dans le scoring. À diagnostiquer via la `rejection_reason` exacte. |
| ❌ `claimMatch` race / double-match | Bug atomicité dans `claim_match` RPC. À diagnostiquer côté serveur. La v2 utilise un pattern différent (FOR UPDATE SKIP LOCKED + advisory lock) qui résout structurellement. |

**MATCHING_V2 reste OFF (et n'est même pas implémenté côté Flutter) pendant ce test.**
