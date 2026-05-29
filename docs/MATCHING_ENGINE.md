# DateNow — Matching Engine (architecture production)

> Mise en relation immédiate, vidéo/audio live, uniquement entre personnes
> disponibles maintenant. Pas de swipe, pas de matching passif.
>
> Toute la logique de matching vit **côté backend**. Le client Flutter est un
> simple acteur (join / heartbeat / events Realtime / accept / decline).

Ce document décrit la **v2** du moteur. Il **étend** le schéma existant
(`matchmaking_queue`, `calls`, `reveals`, `matches`, `user_presence`,
`generate-agora-token`) **sans le casser**.

---

## 0. Principes directeurs

1. **Vérité = Postgres.** Toute opération sensible (matcher, réserver,
   accepter, annuler) est une **transaction SQL** dans une fonction
   `SECURITY DEFINER`. Les Edge Functions sont des **orchestrateurs minces**
   qui authentifient, valident, appellent un RPC, et renvoient une réponse
   typée. Aucune logique métier en TypeScript.
2. **Le client ne décide rien.** Il déclare une intention (join / accept /
   decline) et écoute des événements (Realtime). Toute autorité de matching
   est serveur.
3. **Atomicité sous concurrence.** Verrous d'avis (`pg_advisory_xact_lock`) +
   `FOR UPDATE SKIP LOCKED` pour empêcher double-match, double-claim, ou un
   user présent dans deux files.
4. **Timeouts partout.** Une session, une queue, une proposition acceptable
   ont un `expires_at`. Aucune entrée n'est éternelle.
5. **Ghost-proof.** Heartbeat obligatoire + sweep périodique. Un client
   silencieux disparaît du système.
6. **Local-first realtime.** Le client s'abonne à des **lignes de tables**
   existantes (`calls`, `matchmaking_queue`, `user_presence`, `reveals`).
   Aucun canal Realtime nommé custom n'est requis.
7. **Pas de simplification fragile.** Les sweeps, l'anti-répétition, les
   timeouts et l'audit sont présents dès le jour 1.

---

## 1. Vue d'ensemble — diagramme logique

```
                            ┌──────────────────────────┐
                            │   Flutter client (User)  │
                            │                          │
   ① POST /join-queue       │   listens (Realtime):    │
   ─────────────────────────┤    matchmaking_queue     │
   ② every 12s              │    calls (caller|callee) │
       POST /heartbeat-pres │    user_presence         │
   ───────────────────────► │    reveals               │
                            └────────────┬─────────────┘
                                         │
                          HTTPS (JWT)    │  Realtime (WSS)
                                         ▼
   ┌─────────────────────────────────────────────────────────────┐
   │              Supabase Edge Functions (Deno)                 │
   │  thin orchestrators · auth · validation · 1 RPC each        │
   │                                                             │
   │  join-queue · leave-queue · find-match · accept-match       │
   │  decline-match · create-agora-room · heartbeat-presence     │
   │  cancel-session · session-timeout (cron)                    │
   └─────────────────────────────┬───────────────────────────────┘
                                 │  SQL RPC (SECURITY DEFINER)
                                 ▼
   ┌─────────────────────────────────────────────────────────────┐
   │                  Postgres (Supabase)                        │
   │                                                             │
   │  mm_join_queue · mm_leave_queue · mm_heartbeat              │
   │  mm_find_match · mm_accept_match · mm_decline_match         │
   │  mm_cancel_session · mm_sweep_timeouts                      │
   │                                                             │
   │  tables: matchmaking_queue · calls · reveals · matches      │
   │          user_presence · match_history (NEW) ·              │
   │          queue_events (NEW) · profiles · user_preferences   │
   │                                                             │
   │  pg_cron: every 30s → mm_sweep_timeouts()                   │
   └─────────────────────────────┬───────────────────────────────┘
                                 │  triggers + REPLICA IDENTITY
                                 ▼
   ┌─────────────────────────────────────────────────────────────┐
   │           Supabase Realtime (logical decoding)              │
   │   pushes row changes to subscribed clients (RLS-filtered)   │
   └─────────────────────────────────────────────────────────────┘
```

---

## 2. Cycle de vie d'une session — flux complet

```
USER A                       BACKEND                       USER B
══════                       ═══════                       ══════

POST /join-queue ─────────► mm_join_queue                 (déjà en queue,
                            INSERT matchmaking_queue        heartbeat actif)
                            UPDATE user_presence='searching'
                            INSERT queue_events('joined')
                            ◄──── 200 { queue_id, expires_at }

every 12s
POST /heartbeat-presence ─► mm_heartbeat
                            UPDATE matchmaking_queue.heartbeat_at
                            UPDATE user_presence.updated_at
                            ◄──── 200 { alive: true }

POST /find-match ─────────► mm_find_match
                            ┌─ advisory_xact_lock(self)
                            │  SELECT best peer (score + history penalty)
                            │  FOR UPDATE SKIP LOCKED both rows
                            │  DELETE matchmaking_queue (self + peer)
                            │  INSERT calls (status='waiting',
                            │                accept_expires_at=now()+12s)
                            │  INSERT match_history (outcome='proposed')
                            │  UPDATE user_presence='in_call' (both)
                            └─ commit
                            ◄──── 200 { call_id, peer_id, channel_name,
                                        accept_expires_at, score }

                            ┌─ Realtime push: row INSERT on calls ─────────────┐
                            │   delivered to both users (caller_id|callee_id) │
                            └───────────────────────────────────────────────┬─┘
                                                                            ▼
                                                              client receives
                                                              call_id + shows
                                                              "B veut t'appeler"

POST /accept-match ───────► mm_accept_match
{call_id}                   UPDATE calls.caller_ready = true
                            (if both ready) UPDATE calls.status='live',
                                            room_expires_at=now()+30 min
                            INSERT match_history('accepted')
                            ◄──── 200 { state, both_ready }
                                                                            ▼
                                                              POST /accept-match
                                                              same RPC
                                                              ────────────────►
                                                              callee_ready = true
                                                              → both ready
                                                              → status='live'
                                                              ◄──── 200

POST /create-agora-room ──► verifies calls.status='live'
{call_id}                   delegates to generate-agora-token
                            (existing, untouched)
                            ◄──── 200 { token, channelName, uid, expiresAt }

                                                              POST /create-agora-room
                                                              same flow ─────►
                                                              ◄──── 200 { token... }

                            === Agora session live ===

POST /cancel-session ─────► mm_cancel_session
{call_id, reason}           UPDATE calls.status='ended',
                                   ended_by=self,
                                   end_reason='user_cancel'
                            INSERT match_history('cancelled')
                            UPDATE user_presence='online' (both)
                            ◄──── 200 { ended: true }
                                                                            ▼
                                                              Realtime: calls UPDATE
                                                              delivered → callee
                                                              hangs up locally
```

### Variantes

- **Le second user ne répond pas avant `accept_expires_at`** :
  `mm_sweep_timeouts` détecte (status='waiting' AND accept_expires_at<now()).
  Transitionne en `status='ended', end_reason='accept_timeout'`. Le
  responsive (qui a accepté) est ré-injecté en queue automatiquement avec
  `retry_count++`.
- **L'un decline** : `mm_decline_match` ferme la session, marque
  `match_history.outcome='declined'`. L'autre est ré-injecté en queue.
- **Le client crashe pendant la session** : son heartbeat s'arrête → sweep
  détecte un `calls.status='live'` orphelin (les deux ne sont pas en
  heartbeat) → ferme la session après 30s de silence (`end_reason='ghost'`).
- **Aucun candidat dispo** : `mm_find_match` retourne null. Le client
  attendra le prochain heartbeat ; le serveur ne pousse rien tant qu'aucun
  candidat n'apparaît. Le client peut re-tenter `find-match` toutes les
  5s (côté client) ou attendre un événement `matchmaking_queue` INSERT pour
  retenter (optimisation).

---

## 3. États

### `matchmaking_queue` (entrée)
Pas de colonne `state` : la présence dans la table = "searching".
Une fois matchée, l'entrée est supprimée par `mm_find_match`. Une entrée
expirée (`expires_at < now()`) est supprimée par `mm_sweep_timeouts`.

### `calls.status`
```
   ┌─────────┐  mm_find_match    ┌─────────┐  both ready    ┌──────┐
   │  (none) │ ────────────────► │ waiting │ ─────────────► │ live │
   └─────────┘                   └─────────┘                └──────┘
                                      │                         │
                                      │ accept_timeout          │ cancel / hangup
                                      │ decline                 │ room_timeout
                                      │ cancel                  │ ghost
                                      ▼                         ▼
                                  ┌─────────┐               ┌─────────┐
                                  │  ended  │               │  ended  │
                                  └─────────┘               └─────────┘
                                  end_reason ∈ {
                                    accept_timeout, declined, cancelled,
                                    user_cancel, ghost, normal_end,
                                    room_timeout
                                  }
```

### `user_presence.status`
```
online  ── mm_join_queue ──► searching ── mm_find_match ──► in_call
   ▲                              │                            │
   │  mm_leave_queue / sweep      │ heartbeat stale            │ session ends
   └──────────────────────────────┴────────────────────────────┘
```

---

## 4. Compatibilité & scoring

### Filtres durs (compatibilité ou rejet)
1. `profiles.is_banned = false` (les deux côtés)
2. Pas dans `blocked_users` ni dans un sens ni dans l'autre
3. Pas de `match_history` négatif récent (cf. anti-répétition)
4. Genre/orientation : compatibilité **bidirectionnelle**
   - `peer.gender ∈ self.user_preferences.seeking_genders` (ou seeking vide = ouvert)
   - `self.gender ∈ peer.user_preferences.seeking_genders` (idem)
5. Âge : bidirectionnel
   - `age(peer.birth_date) BETWEEN self.seeking_age_min..max`
   - et symétrique pour self
6. Distance : `ST_Distance(self.location, peer.location) ≤ LEAST(self.max_distance_km, peer.max_distance_km) × 1000`
7. Disponibilité live : présents dans `matchmaking_queue` avec
   `expires_at > now()` et `heartbeat_at > now() - 30s`

### Scoring (0..100, additif)
| Dimension     | Poids | Formule (court) |
|---------------|------:|-----------------|
| Distance      | 40    | `40 × (1 − clamp(dist_m / max_dist_m, 0, 1))` |
| Langues       | 15    | `15 × jaccard(self.languages, peer.languages)` |
| Intérêts      | 20    | `20 × jaccard(self.interests, peer.interests)` |
| Écart d'âge   | 10    | `10 × (1 − clamp(abs(age_a − age_b) / 15, 0, 1))` |
| Fraîcheur queue | 15  | `15 × exp(−(now − peer.joined) / 60s)` (favorise les arrivées récentes) |

### Pénalité d'historique (anti-répétition douce)
Multiplicateur appliqué au score final selon la pire pénalité applicable :

| Outcome passé entre le couple ordonné (a,b) | Fenêtre   | Effet sur score |
|---------------------------------------------|-----------|-----------------|
| `declined` ou `timed_out` ou `cancelled`    | < 1 h     | **× 0** (hard exclude) |
| `accepted` mais session courte (< 60 s)     | < 6 h     | × 0.4 |
| Tout outcome                                | < 24 h    | × 0.6 |
| `completed` avec score < 30                 | < 7 j     | × 0.8 |
| (aucun match)                               | —         | × 1.0 |

Le score effectif doit dépasser `p_min_score` (par défaut **40**) sinon
`mm_find_match` retourne `NULL` (= « pas de candidat assez bon, attends »).

### Stratégie en cas de pénurie
Quand la queue est petite (< 5 candidats compatibles) :
1. **Relax progressif côté queue** : `mm_find_match` accepte
   `p_min_score=20` après 30s d'attente (le client peut renvoyer avec un
   seuil plus bas via la queue heartbeat).
2. **Élargissement géographique** : `max_distance_km` × 1.5 (configurable
   serveur, jamais client).
3. **Notification "élargi"** : on renvoie `score < 40` mais on remonte
   `relaxed: true` dans la réponse pour que le client puisse afficher
   "match élargi".
4. **Backoff** : si toujours rien après 5 min (queue TTL), le client est
   sorti automatiquement et reçoit un événement Realtime
   (`matchmaking_queue` DELETE) → UI : « personne d'actif, réessaye plus tard ».

### Exclusions définitives
- Profils dans `reports.status='reviewed'` avec ban → `is_banned=true` (déjà
  filtré).
- Couples ayant produit un `matches` row avec `status='conversation_open'`
  ou `'archived'` : exclus (déjà en conversation).

---

## 5. Temps réel & robustesse

### Fréquences
| Quoi                            | Fréquence       | Source       |
|---------------------------------|-----------------|--------------|
| Heartbeat client (queue + pres) | **12 s**        | Flutter timer |
| Stale threshold                 | 30 s sans heartbeat | sweep |
| Queue TTL (TTL d'une entrée)    | **5 min**       | `expires_at` colonne |
| Acceptance timeout              | **12 s**        | `calls.accept_expires_at` |
| Room TTL (hard cap)             | **30 min**      | `calls.room_expires_at` |
| Token Agora TTL                 | 15 min          | existing |
| Sweep cron                      | **30 s**        | pg_cron |
| Find-match retry côté client    | 3 s             | Flutter (event-driven préféré) |
| Find-match retry max attempts   | illimité tant que queue active | — |

### Retry policy

| Échec                  | Côté serveur                          | Côté client          |
|------------------------|---------------------------------------|----------------------|
| `find-match` no candidate | Marqueur silencieux, queue intacte | Patiente 3 s, retry. Idéal : attendre event Realtime `matchmaking_queue INSERT` puis retry. |
| `find-match` race (peer pris) | RPC retourne 409 `peer_taken` | Retry immédiat |
| `accept-match` 409 (déjà ended) | — | Affiche "session expirée", retour queue |
| `accept_timeout` (autre user) | Sweep ferme calls, re-queue le responsive avec `retry_count+1` | Reçoit Realtime UPDATE `calls.status='ended', end_reason='accept_timeout'` → reste en queue |
| Edge Function 5xx      | log + retourne 503                    | Retry exponentiel (200ms, 600ms, 1.8s, abort) |
| Heartbeat manqué (1×)  | aucun (12s ≤ 30s threshold)           | retry timer suivant |
| Heartbeat manqué (3×, 36 s) | Sweep retire de queue                 | reconnect → re-join |

### Reconnexion
Au reprise foreground (Flutter `AppLifecycleState.resumed`) :
1. Le client appelle `heartbeat-presence` immédiatement.
2. Si la réponse indique `queue_alive=false`, il appelle `join-queue` à nouveau.
3. Il rafraîchit l'abonnement Realtime sur `calls` et `matchmaking_queue`.

### Ghost prevention
Sweep examine :
- `matchmaking_queue` où `heartbeat_at < now() - 30s` → DELETE + log
- `calls.status='waiting'` où `accept_expires_at < now()` → UPDATE status='ended', end_reason='accept_timeout'
- `calls.status='live'` où `room_expires_at < now()` → UPDATE status='ended', end_reason='room_timeout'
- `calls.status='live'` où **aucun des deux** participants n'a un heartbeat
  ou une presence < 30s → UPDATE status='ended', end_reason='ghost'

### Cleanup auto
- pg_cron `mm_sweep_timeouts()` chaque 30s.
- Vacuum / archive : `queue_events` est purgé > 30 j (`mm_purge_old_events()`).
- `match_history` est conservé (utilisé en anti-repeat ; volume contrôlé,
  partitionnable par `created_at` si besoin > 100M lignes).

---

## 6. Scalabilité

### Capacité Postgres seul
À 10k utilisateurs simultanés en queue, `mm_find_match` reste sub-100ms si :
- Index sur `matchmaking_queue (expires_at)`, `(heartbeat_at)`, `(user_id)`.
- Index GIST sur `profiles.location` (déjà présent).
- Index sur `match_history (user_a, user_b, created_at DESC)` pour la
  lookup anti-répétition.
- Le candidat pool est filtré tôt (genre + queue actif) puis trié par
  score sur N candidats restants.

### Anti-double-match (race)
Trois protections empilées :
1. **`pg_advisory_xact_lock(hashtext('mm_find_match:'||self_id))`** :
   un même user ne peut pas exécuter `mm_find_match` deux fois en
   parallèle (deux devices).
2. **`FOR UPDATE SKIP LOCKED`** sur les rows queue à supprimer : si un
   autre `mm_find_match` a déjà verrouillé l'une des deux, on échoue
   proprement avec `peer_taken`.
3. **Contrainte unique implicite** : `calls` n'a pas d'unique sur la paire,
   mais la suppression atomique de `matchmaking_queue` garantit qu'un
   user ne peut être dans deux calls simultanées (vérif explicite au début
   de `mm_join_queue` et `mm_find_match`).

### Anti-double-queue
- `matchmaking_queue.user_id` est `UNIQUE` (déjà). `INSERT ... ON CONFLICT`
  fait un upsert idempotent.

### Pas de polling inutile
- Le client ne **poll pas** `find-match` agressivement. Il l'appelle :
  - 1 fois immédiatement après `join-queue` ;
  - puis sur `matchmaking_queue` INSERT (Realtime) — un nouveau peer = retry ;
  - en fallback toutes les 5 s côté client (jitter ±1s).

### Où Redis devient pertinent
**Pas avant** :
- 50k+ utilisateurs simultanés en queue **soutenus** ;
- Latence p99 `mm_find_match` qui dépasse 250 ms ;
- Besoin de calculs de candidate-pool très complexes (recherche
  géo-spatiale + facettes multiples) plus rapide qu'index GIST/B-tree
  Postgres.

Quand on franchit ce seuil, le plan recommandé est :
1. Garder Postgres comme source de vérité (calls, matches, history, RLS).
2. Maintenir un **mirror Redis** de la queue (sorted set par geohash
   `mm:queue:<geohash>`) mis à jour via triggers Postgres → NOTIFY → worker
   Deno → Redis.
3. `mm_find_match` (Edge Function) interroge d'abord Redis pour
   pré-filtrer, puis Postgres pour la réservation atomique
   (`FOR UPDATE SKIP LOCKED`). La cohérence finale reste Postgres.

Tant que ce seuil n'est pas atteint : **Postgres only**. C'est simple,
transactionnel, observable, et tient confortablement le MVP et bien
au-delà.

---

## 7. Inventaire des artefacts

### Tables (nouvelles colonnes en gras)
| Table | Existante ? | Ajouts |
|-------|------------|--------|
| `matchmaking_queue` | oui | **`expires_at TIMESTAMPTZ`**, **`client_id TEXT`**, **`retry_count INT`** |
| `calls` | oui | **`accept_expires_at TIMESTAMPTZ`**, **`room_expires_at TIMESTAMPTZ`**, **`end_reason TEXT`** |
| `user_preferences` | oui | **`languages TEXT[]`** |
| `match_history` | NEW | id, user_a, user_b (ordonné), call_id, outcome, created_at |
| `queue_events` | NEW | id, user_id, event, payload JSONB, created_at |

### Fonctions SQL (`mm_*`)
- `mm_join_queue(p_client_id) → row(queue_id, expires_at)`
- `mm_leave_queue() → boolean`
- `mm_heartbeat() → row(queue_alive, presence_status)`
- `mm_find_match(p_min_score INT DEFAULT 40, p_relax_after_seconds INT DEFAULT 30) → row(call_id, peer_id, channel_name, accept_expires_at, score, relaxed)`
- `mm_accept_match(p_call_id) → row(state, both_ready, channel_name)`
- `mm_decline_match(p_call_id, p_reason TEXT) → boolean`
- `mm_cancel_session(p_call_id, p_reason TEXT) → boolean`
- `mm_sweep_timeouts() → row(queue_expired INT, calls_accept_timeout INT, calls_room_timeout INT, calls_ghost INT)`
- `mm_history_penalty(p_a UUID, p_b UUID) → numeric` (helper)

### Edge Functions (Deno / TypeScript)
| Function | Méthode | Auth | Body | Réponse |
|----------|---------|------|------|---------|
| `join-queue` | POST | Bearer | `{ client_id?: string }` | `{ queue_id, expires_at }` |
| `leave-queue` | POST | Bearer | — | `{ left: bool }` |
| `find-match` | POST | Bearer | `{ min_score?: int }` | `{ matched: bool, call_id?, peer_id?, channel_name?, accept_expires_at?, score?, relaxed? }` |
| `accept-match` | POST | Bearer | `{ call_id }` | `{ state, both_ready, channel_name }` |
| `decline-match` | POST | Bearer | `{ call_id, reason? }` | `{ declined: true }` |
| `create-agora-room` | POST | Bearer | `{ call_id, uid: int }` | `{ token, appId, channelName, uid, expiresAt }` (proxie `generate-agora-token`) |
| `heartbeat-presence` | POST | Bearer | — | `{ queue_alive, presence_status }` |
| `cancel-session` | POST | Bearer | `{ call_id, reason? }` | `{ ended: true }` |
| `session-timeout` | POST | **Cron secret** | — | `{ queue_expired, calls_accept_timeout, calls_room_timeout, calls_ghost }` |

### Cron
- pg_cron `*/30 * * * * *` (toutes les 30 s) — invoque `mm_sweep_timeouts()`.
- Supabase Cron (optionnel, monitoring externe) — appelle l'Edge Function
  `session-timeout` toutes les minutes, avec un secret partagé.

---

## 8. RLS — politiques

| Table              | SELECT                                      | INSERT/UPDATE/DELETE       |
|--------------------|---------------------------------------------|----------------------------|
| `matchmaking_queue`| `authenticated`                              | `auth.uid() = user_id`     |
| `calls`            | participant (`caller_id` ou `callee_id`)     | participant                |
| `user_presence`    | `authenticated`                              | `auth.uid() = user_id`     |
| `match_history`    | participant (`user_a` ou `user_b`)           | **aucun (SECURITY DEFINER)**|
| `queue_events`     | **aucun (service_role only)**                | **aucun (SECURITY DEFINER)**|
| `reveals`          | participant via call (existant)              | propriétaire (existant)    |
| `matches`          | participant (existant)                       | (créé par fonctions)       |

Les RPC `mm_*` sont en `SECURITY DEFINER` avec `SET search_path = public`
et un check `auth.uid() IS NOT NULL` en tête. Aucune mutation business
n'est faite directement par le client.

---

## 9. Structure des dossiers

```
supabase/
├── migrations/
│   ├── 20260513120000_initial_schema.sql        (existant)
│   ├── ...
│   ├── 20260517120000_matchmaking.sql           (existant — v1)
│   ├── 20260517150000_presence.sql              (existant)
│   └── 20260528120000_matching_engine_v2.sql    (NEW — additif)
├── functions/
│   ├── _shared/                                 (NEW)
│   │   ├── cors.ts
│   │   ├── auth.ts
│   │   ├── supabase.ts
│   │   ├── errors.ts
│   │   └── logger.ts
│   ├── generate-agora-token/                    (existant — intact)
│   ├── message-notification/                    (existant — intact)
│   ├── delete-account/                          (existant — intact)
│   ├── join-queue/index.ts                      (NEW)
│   ├── leave-queue/index.ts                     (NEW)
│   ├── find-match/index.ts                      (NEW)
│   ├── accept-match/index.ts                    (NEW)
│   ├── decline-match/index.ts                   (NEW)
│   ├── create-agora-room/index.ts               (NEW)
│   ├── heartbeat-presence/index.ts              (NEW)
│   ├── cancel-session/index.ts                  (NEW)
│   └── session-timeout/index.ts                 (NEW — cron)
└── MATCHING_DEPLOY.md                           (NEW — runbook)

docs/
└── MATCHING_ENGINE.md                           (NEW — ce document)
```

---

## 10. Cohabitation avec l'existant

- Le frontend Flutter actuel utilise les RPC `find_best_live_candidate_v1`
  et `claim_match`. Ces RPC restent **intactes et fonctionnelles**. Les
  nouvelles RPC `mm_*` cohabitent. La migration côté Flutter peut se
  faire ultérieurement (changer les appels `rpc(...)` pour
  `functions.invoke('find-match')`, etc.). **Le frontend n'est pas modifié
  ici.**
- `generate-agora-token` n'est **pas remplacée**. `create-agora-room`
  l'appelle en interne (via fetch HTTP au sein de l'Edge runtime).
- Les Realtime subscriptions du client (sur `calls`, `matchmaking_queue`,
  `reveals`, `user_presence`) continuent de fonctionner sans changement.
- Les colonnes ajoutées sont toutes `NULL`-tolérantes ou ont un `DEFAULT`,
  ce qui n'invalide aucun INSERT existant.

---

## 11. Observabilité

- `queue_events` capture les transitions (joined, left, expired, matched,
  declined, timeout). Service-role only — pratique pour tableaux de bord.
- Chaque Edge Function logue avec un préfixe `[mm/<name>] requestId=...`
  pour grep simple dans Supabase Logs Explorer.
- `mm_sweep_timeouts()` renvoie ses compteurs : on les pousse dans les
  logs cron pour suivre la santé.

### Métriques recommandées
- p50 / p99 de `mm_find_match` (Postgres).
- Taux d'`accept_timeout` (proportion de waiting → ended via timeout).
- Taux de `ghost` sur calls live.
- Temps médian en queue avant match.
- Distribution des scores au moment du match.

### Tableaux de bord (Supabase Studio)
Queries prêtes à coller (à mettre dans `supabase/dashboards/`, hors scope
de cette livraison) :
```sql
-- Sessions des 24 dernières heures par end_reason
SELECT end_reason, count(*)
FROM calls
WHERE started_at > now() - interval '24 hours'
GROUP BY end_reason;
```

---

## 12. Production checklist

1. **Secrets** définis dans Supabase Dashboard (Functions → Secrets) :
   - `MATCHING_CRON_SECRET` (32+ caractères, partagé entre cron et
     `session-timeout`).
   - `AGORA_APP_ID`, `AGORA_APP_CERTIFICATE` (déjà présents).
2. **pg_cron** activé : `CREATE EXTENSION IF NOT EXISTS pg_cron;`
   (Supabase doit activer l'extension via dashboard ; voir
   `MATCHING_DEPLOY.md`).
3. **Realtime** publié pour `matchmaking_queue`, `calls`, `user_presence`,
   `reveals` (déjà fait pour la v1 ; à vérifier après migration).
4. **Politiques RLS** vérifiées via tests SQL (cf. `supabase/tests/`).
5. **Backups** : la table `match_history` peut grossir vite ; activer le
   point-in-time recovery est déjà standard sur Supabase. Plan de
   partitioning prêt si > 100M lignes.
6. **Rate-limiting** sur les Edge Functions (Supabase Dashboard) :
   - `join-queue` / `find-match` : 60 req/min par IP, 30 req/min par user.
   - `heartbeat-presence` : 120 req/min par user (au plus une toutes les 0.5s).
7. **Monitoring** : alerte sur taux de `ghost > 5%` ou p99 `mm_find_match
   > 500 ms`.
8. **Tests de charge** : `k6` sur `/find-match` à 200 RPS pendant 10 min,
   p99 < 250 ms attendu sur instance Supabase Pro.

---

## 13. Ce que ce document NE fait PAS

- ❌ Pas de modification frontend Flutter (le client basculera dans un
  travail séparé).
- ❌ Pas de modification de `generate-agora-token`.
- ❌ Pas de modification de l'auth, des flux onboarding, ni du schéma
  `profiles` / `user_preferences` existant (seules des colonnes
  additionnelles non-bloquantes sont ajoutées).
- ❌ Pas de Redis pour cette livraison (Postgres tient le MVP et au-delà).
- ❌ Pas de simplification fragile : timeouts, anti-repeat, sweeps et audit
  sont présents dès la première version.
