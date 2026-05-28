# DateNow — Déploiement du matching engine v2

Runbook de mise en production du **socle matching temps réel** (migration v2 +
9 Edge Functions + sweep).

> Conception et flux complets : [`docs/MATCHING_ENGINE.md`](../docs/MATCHING_ENGINE.md).

---

## 0. Prérequis

- Projet Supabase accessible (`supabase link` déjà fait).
- Secrets existants en place : `AGORA_APP_ID`, `AGORA_APP_CERTIFICATE`,
  `APNS_*` (pour `message-notification`).
- Branche git de travail dédiée recommandée (ex. `feat/matching-engine-v2`).
- Aucune modification du frontend Flutter ni des Edge Functions existantes
  n'est nécessaire — la livraison est **additive**.

---

## 1. Nouveaux secrets

| Secret | Quoi | Où |
|---|---|---|
| `MATCHING_CRON_SECRET` | Token partagé entre cron externe et `session-timeout`. 32+ caractères. | `supabase secrets set` |

```bash
# Générer une valeur forte (macOS / Linux)
openssl rand -hex 32

# Pousser dans Supabase
supabase secrets set MATCHING_CRON_SECRET=<valeur>
```

Aucun autre secret nouveau. `AGORA_*` reste utilisé par
`generate-agora-token` (inchangé) ; `create-agora-room` n'a pas besoin de
la clé Agora.

---

## 2. Activer `pg_cron` (une seule fois)

Le sweep automatique est déclenché par `pg_cron` en base. Si l'extension
n'est pas active sur le projet :

1. Supabase Dashboard → **Database › Extensions** → `pg_cron` → **Enable**.
2. Si tu préfères en SQL (rôle `postgres`) :
   ```sql
   CREATE EXTENSION IF NOT EXISTS pg_cron;
   ```

La migration v2 contient un bloc qui **détecte** la présence de `pg_cron`
et planifie deux jobs idempotents (`mm_sweep_timeouts` chaque minute,
`mm_purge_old_events` quotidien à 03:15). Si l'extension n'est pas
encore active, le bloc est silencieusement ignoré : applique la migration,
puis active `pg_cron`, puis ré-exécute la migration ou crée les jobs
manuellement :

```sql
SELECT cron.schedule(
  'mm_sweep_timeouts', '* * * * *',
  $$SELECT public.mm_sweep_timeouts();$$
);
SELECT cron.schedule(
  'mm_purge_old_events', '15 3 * * *',
  $$SELECT public.mm_purge_old_events();$$
);
```

> **Alternative sans pg_cron** : laisser `pg_cron` désactivé et invoquer
> l'Edge Function `session-timeout` toutes les minutes via Supabase Cron
> (Dashboard) ou un scheduler externe, avec le header
> `X-Cron-Secret: $MATCHING_CRON_SECRET`. Mêmes effets ; latence
> légèrement supérieure (network hop).

---

## 3. Appliquer la migration SQL

```bash
cd ~/datenow
supabase db push
```

La migration `20260528120000_matching_engine_v2.sql` :
- ajoute des colonnes (`expires_at`, `client_id`, `retry_count` sur
  `matchmaking_queue` ; `accept_expires_at`, `room_expires_at`,
  `end_reason` sur `calls` ; `languages` sur `user_preferences`) ;
- crée les tables `match_history` et `queue_events` ;
- crée les fonctions `mm_*` ;
- pose les `GRANT` (authenticated → fonctions client ; service_role →
  sweep) ;
- programme les jobs `pg_cron` si l'extension est active.

Toutes les opérations sont `IF NOT EXISTS` ou `CREATE OR REPLACE` :
ré-appliquer la migration sans rien changer est sûr.

### Vérification post-migration

```sql
-- 1) Colonnes ajoutées
SELECT column_name FROM information_schema.columns
 WHERE table_schema='public' AND table_name='matchmaking_queue'
   AND column_name IN ('expires_at','client_id','retry_count');

SELECT column_name FROM information_schema.columns
 WHERE table_schema='public' AND table_name='calls'
   AND column_name IN ('accept_expires_at','room_expires_at','end_reason');

-- 2) Tables créées
SELECT table_name FROM information_schema.tables
 WHERE table_schema='public' AND table_name IN ('match_history','queue_events');

-- 3) Fonctions présentes
SELECT proname FROM pg_proc
 WHERE pronamespace='public'::regnamespace
   AND proname LIKE 'mm\_%' ESCAPE '\';

-- 4) Cron jobs
SELECT jobname, schedule FROM cron.job
 WHERE jobname IN ('mm_sweep_timeouts','mm_purge_old_events');
```

---

## 4. Déployer les Edge Functions

Les fonctions partagent du code via `_shared/` (résolu par Supabase CLI).

```bash
# Déploiement individuel — à faire pour chaque nouvelle fonction
supabase functions deploy join-queue           --no-verify-jwt=false
supabase functions deploy leave-queue          --no-verify-jwt=false
supabase functions deploy find-match           --no-verify-jwt=false
supabase functions deploy accept-match         --no-verify-jwt=false
supabase functions deploy decline-match        --no-verify-jwt=false
supabase functions deploy create-agora-room    --no-verify-jwt=false
supabase functions deploy heartbeat-presence   --no-verify-jwt=false
supabase functions deploy cancel-session       --no-verify-jwt=false
supabase functions deploy session-timeout      --no-verify-jwt=false
```

> `--no-verify-jwt=false` (par défaut sur Supabase) impose un JWT
> Supabase valide. `session-timeout` ajoute son propre contrôle par
> secret cron (header `X-Cron-Secret`) **en plus** du JWT — pour le
> trigger cron externe, utilise n'importe quel JWT anon valide + le
> bon `X-Cron-Secret`. (Si tu veux exposer `session-timeout` sans JWT,
> redéploie avec `--no-verify-jwt=true` ; le secret cron reste alors la
> seule protection.)

Les Edge Functions existantes — `generate-agora-token`,
`message-notification`, `delete-account` — ne sont **pas** redéployées
ici, elles restent intactes.

---

## 5. Smoke test

Remplace `<JWT>` par un token utilisateur Supabase (issu d'une session
auth Flutter dev). Remplace `<PROJ>` par le sous-domaine du projet.

```bash
BASE=https://<PROJ>.supabase.co/functions/v1
H=(-H "Authorization: Bearer <JWT>" -H "Content-Type: application/json")

# 1. Rejoindre la file
curl -s -X POST "$BASE/join-queue" "${H[@]}" -d '{}' | jq

# 2. Heartbeat
curl -s -X POST "$BASE/heartbeat-presence" "${H[@]}" -d '{}' | jq

# 3. Chercher un match (besoin d'un autre user en file pour matcher)
curl -s -X POST "$BASE/find-match" "${H[@]}" -d '{"min_score":40}' | jq

# 4. Accepter (le call_id vient de l'étape 3)
curl -s -X POST "$BASE/accept-match" "${H[@]}" -d '{"call_id":"<call_id>"}' | jq

# 5. Obtenir un token Agora pour le room (uid arbitraire, int32 positif)
curl -s -X POST "$BASE/create-agora-room" "${H[@]}" \
  -d '{"call_id":"<call_id>","uid":1234567}' | jq

# 6. Fin de session
curl -s -X POST "$BASE/cancel-session" "${H[@]}" \
  -d '{"call_id":"<call_id>","reason":"normal_end"}' | jq

# 7. Sweep (cron secret obligatoire)
curl -s -X POST "$BASE/session-timeout" \
  -H "X-Cron-Secret: $MATCHING_CRON_SECRET" \
  -H "Content-Type: application/json" -d '{}' | jq
```

Réponses attendues : voir `docs/MATCHING_ENGINE.md` §7 (Inventaire).

---

## 6. Vérifier Realtime

Les flux temps réel s'appuient sur les publications existantes
(`matchmaking_queue`, `calls`, `reveals`, `user_presence`). Vérifier :

```sql
SELECT schemaname, tablename
  FROM pg_publication_tables
 WHERE pubname = 'supabase_realtime'
   AND tablename IN ('matchmaking_queue','calls','reveals','user_presence');
```

Les nouvelles tables `match_history` et `queue_events` n'ont **pas
besoin** d'être publiées (audit / historique côté serveur, jamais
streamées au client).

---

## 7. Observabilité

### Logs des Edge Functions
Préfixe `[mm/<name>] requestId=<uuid>` → filtrable dans Supabase
**Logs Explorer**. Utiliser `event_message ~ '\[mm/find-match\]'`
pour cibler une fonction.

### Métriques utiles (SQL)
```sql
-- Distribution des fins de session des 24 dernières heures
SELECT end_reason, count(*)
  FROM calls
 WHERE started_at > now() - interval '24 hours'
 GROUP BY end_reason
 ORDER BY 2 DESC;

-- Temps médian passé en file avant match (s)
SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (qe.created_at - q1.created_at))) AS p50_seconds
  FROM queue_events qe
  JOIN queue_events q1 ON q1.user_id = qe.user_id
                       AND q1.event = 'joined'
                       AND q1.created_at <= qe.created_at
 WHERE qe.event = 'matched'
   AND qe.created_at > now() - interval '24 hours';

-- Volume du sweep sur la dernière heure (depuis pg_cron run history)
SELECT command, status, return_message, start_time
  FROM cron.job_run_details
 WHERE jobname IN ('mm_sweep_timeouts','mm_purge_old_events')
   AND start_time > now() - interval '1 hour'
 ORDER BY start_time DESC LIMIT 20;
```

### Seuils d'alerte recommandés
- Taux de `end_reason='ghost'` > 5 % sur 1 h → enquêter (réseau, OEM kill).
- Taux d'`accept_timeout` > 30 % → l'UX d'acceptation manque de signaux.
- `mm_find_match` p99 > 250 ms en charge → vérifier plans Postgres, taille
  de pool, et activer la stratégie Redis décrite dans
  `docs/MATCHING_ENGINE.md` §6.

---

## 8. Rollback

La migration v2 est **additive**. Pour annuler :

```sql
-- 1. Stopper les jobs cron
SELECT cron.unschedule(jobid) FROM cron.job
 WHERE jobname IN ('mm_sweep_timeouts','mm_purge_old_events');

-- 2. (Optionnel) Supprimer les fonctions mm_*
DROP FUNCTION IF EXISTS public.mm_find_match(INT) CASCADE;
DROP FUNCTION IF EXISTS public.mm_join_queue(TEXT) CASCADE;
DROP FUNCTION IF EXISTS public.mm_leave_queue() CASCADE;
DROP FUNCTION IF EXISTS public.mm_heartbeat() CASCADE;
DROP FUNCTION IF EXISTS public.mm_accept_match(UUID) CASCADE;
DROP FUNCTION IF EXISTS public.mm_decline_match(UUID, TEXT) CASCADE;
DROP FUNCTION IF EXISTS public.mm_cancel_session(UUID, TEXT) CASCADE;
DROP FUNCTION IF EXISTS public.mm_sweep_timeouts() CASCADE;
DROP FUNCTION IF EXISTS public.mm_purge_old_events() CASCADE;
DROP FUNCTION IF EXISTS public.mm_history_penalty(UUID, UUID) CASCADE;
DROP FUNCTION IF EXISTS public.mm_jaccard(TEXT[], TEXT[]) CASCADE;

-- 3. (Optionnel) Tables nouvelles
DROP TABLE IF EXISTS public.queue_events;
DROP TABLE IF EXISTS public.match_history;
```

Les colonnes ajoutées (`expires_at`, `accept_expires_at`, etc.) peuvent
rester sans effet sur le code legacy (qui les ignorera), ou être
retirées :

```sql
ALTER TABLE public.matchmaking_queue
  DROP COLUMN IF EXISTS expires_at,
  DROP COLUMN IF EXISTS client_id,
  DROP COLUMN IF EXISTS retry_count;
ALTER TABLE public.calls
  DROP COLUMN IF EXISTS accept_expires_at,
  DROP COLUMN IF EXISTS room_expires_at,
  DROP COLUMN IF EXISTS end_reason;
ALTER TABLE public.user_preferences
  DROP COLUMN IF EXISTS languages;
```

Côté Edge Functions, supprimer simplement les nouveaux dossiers :

```bash
supabase functions delete join-queue leave-queue find-match accept-match \
  decline-match create-agora-room heartbeat-presence cancel-session session-timeout
```

Les anciennes RPC (`find_best_live_candidate_v1`, `claim_match`,
`queue_heartbeat`, `set_presence`) restent fonctionnelles tout au long
de la migration → le frontend continue de marcher tel quel.

---

## 9. Étape suivante (hors livraison)

Une fois le moteur stable côté serveur :
1. Migrer progressivement les appels Flutter de `rpc(...)` vers
   `functions.invoke('...')` (PR séparée, non incluse ici).
2. Désactiver `find_best_live_candidate_v1` et `claim_match` quand plus
   aucun client legacy ne les appelle.
3. Activer Redis (cf. `docs/MATCHING_ENGINE.md` §6) **si et seulement si**
   la latence p99 dépasse 250 ms sous charge réelle.
