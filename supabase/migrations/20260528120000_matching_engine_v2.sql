-- ============================================================================
-- DateNow — Matching Engine v2 (additive, production)
--
-- Étend le moteur de matching existant (matchmaking_queue, calls, reveals,
-- matches, user_presence, find_best_live_candidate_v1, claim_match) avec :
--   • TTL et timeouts (queue + acceptance + room TTL)
--   • Anti-répétition (table match_history, pénalité de score)
--   • Langue dans le scoring (extension user_preferences)
--   • Audit (table queue_events)
--   • RPC mm_* (orchestration transactionnelle complète)
--   • Sweep automatique (mm_sweep_timeouts via pg_cron toutes les minutes)
--
-- Conventions :
--   • Toutes les opérations sont additives et idempotentes.
--   • Toutes les fonctions sont SECURITY DEFINER, search_path verrouillé.
--   • Aucune logique métier en-dehors de Postgres : les Edge Functions
--     délèguent exclusivement à ces fonctions.
--
-- Pour le détail de l'architecture : docs/MATCHING_ENGINE.md
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Extensions de schéma (additives)
-- ---------------------------------------------------------------------------

-- 1.1 matchmaking_queue : TTL + contexte client + tentatives
ALTER TABLE public.matchmaking_queue
    ADD COLUMN IF NOT EXISTS expires_at TIMESTAMPTZ NOT NULL DEFAULT (now() + interval '5 minutes'),
    ADD COLUMN IF NOT EXISTS client_id TEXT,
    ADD COLUMN IF NOT EXISTS retry_count INT NOT NULL DEFAULT 0;

CREATE INDEX IF NOT EXISTS matchmaking_queue_expires_idx
    ON public.matchmaking_queue (expires_at);
CREATE INDEX IF NOT EXISTS matchmaking_queue_heartbeat_idx
    ON public.matchmaking_queue (heartbeat_at);

-- 1.2 calls : deadlines + raison de fin
ALTER TABLE public.calls
    ADD COLUMN IF NOT EXISTS accept_expires_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS room_expires_at   TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS end_reason        TEXT;

-- contrainte souple sur end_reason (valeurs connues, mais on laisse passer
-- les futures sans casser la migration en cas de typo en prod)
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.table_constraints
        WHERE table_schema='public' AND table_name='calls'
          AND constraint_name='calls_end_reason_chk'
    ) THEN
        ALTER TABLE public.calls
          ADD CONSTRAINT calls_end_reason_chk
          CHECK (end_reason IS NULL OR end_reason IN (
            'accept_timeout','declined','cancelled','user_cancel',
            'ghost','normal_end','room_timeout'
          ));
    END IF;
END $$;

CREATE INDEX IF NOT EXISTS calls_status_accept_expires_idx
    ON public.calls (status, accept_expires_at)
    WHERE status = 'waiting';
CREATE INDEX IF NOT EXISTS calls_status_room_expires_idx
    ON public.calls (status, room_expires_at)
    WHERE status = 'live';

-- 1.3 user_preferences : préférences linguistiques
ALTER TABLE public.user_preferences
    ADD COLUMN IF NOT EXISTS languages TEXT[] NOT NULL DEFAULT '{}';

-- ---------------------------------------------------------------------------
-- 2. Nouvelles tables
-- ---------------------------------------------------------------------------

-- 2.1 match_history : registre des interactions passées (anti-repeat)
CREATE TABLE IF NOT EXISTS public.match_history (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_a      UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    user_b      UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    call_id     UUID REFERENCES public.calls(id) ON DELETE SET NULL,
    outcome     TEXT NOT NULL CHECK (outcome IN (
                    'proposed','accepted','declined','timed_out',
                    'completed','cancelled'
                )),
    metadata    JSONB,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (user_a < user_b)
);

CREATE INDEX IF NOT EXISTS match_history_pair_recent_idx
    ON public.match_history (user_a, user_b, created_at DESC);
CREATE INDEX IF NOT EXISTS match_history_user_a_recent_idx
    ON public.match_history (user_a, created_at DESC);
CREATE INDEX IF NOT EXISTS match_history_user_b_recent_idx
    ON public.match_history (user_b, created_at DESC);

ALTER TABLE public.match_history ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS match_history_select_participant ON public.match_history;
CREATE POLICY match_history_select_participant
    ON public.match_history FOR SELECT
    TO authenticated
    USING (auth.uid() = user_a OR auth.uid() = user_b);
-- INSERT / UPDATE / DELETE réservés aux SECURITY DEFINER (aucune policy explicite).

-- 2.2 queue_events : audit du cycle de vie de la file
CREATE TABLE IF NOT EXISTS public.queue_events (
    id          BIGSERIAL PRIMARY KEY,
    user_id     UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    event       TEXT NOT NULL CHECK (event IN (
                    'joined','left','expired','matched','declined',
                    'timeout','heartbeat_stale'
                )),
    payload     JSONB,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS queue_events_user_recent_idx
    ON public.queue_events (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS queue_events_recent_idx
    ON public.queue_events (created_at DESC);

ALTER TABLE public.queue_events ENABLE ROW LEVEL SECURITY;
-- aucune policy : service_role uniquement (audit interne).

-- ---------------------------------------------------------------------------
-- 3. Helpers pure SQL
-- ---------------------------------------------------------------------------

-- Jaccard sur deux arrays texte (utilisé par le scoring).
CREATE OR REPLACE FUNCTION public.mm_jaccard(a TEXT[], b TEXT[])
RETURNS NUMERIC
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
    SELECT CASE
        WHEN (a IS NULL OR cardinality(a) = 0)
         AND (b IS NULL OR cardinality(b) = 0) THEN 0
        ELSE
            COALESCE((
                SELECT cardinality(ARRAY(SELECT unnest(a) INTERSECT SELECT unnest(b)))::numeric
                       / NULLIF(
                             cardinality(ARRAY(SELECT unnest(a) UNION SELECT unnest(b)))::numeric,
                             0
                         )
            ), 0)
    END;
$$;

-- Pénalité multiplicative liée à l'historique d'un couple ordonné (a < b).
-- Retourne un facteur dans [0, 1] appliqué au score brut.
CREATE OR REPLACE FUNCTION public.mm_history_penalty(p_a UUID, p_b UUID)
RETURNS NUMERIC
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_a UUID := LEAST(p_a, p_b);
    v_b UUID := GREATEST(p_a, p_b);
BEGIN
    -- Hard-exclude : interaction négative dans la dernière heure.
    IF EXISTS (
        SELECT 1 FROM public.match_history
         WHERE user_a = v_a AND user_b = v_b
           AND outcome IN ('declined','timed_out','cancelled')
           AND created_at > now() - interval '1 hour'
    ) THEN
        RETURN 0;
    END IF;

    -- Session terminée récemment (< 6 h) : forte réduction.
    IF EXISTS (
        SELECT 1 FROM public.match_history
         WHERE user_a = v_a AND user_b = v_b
           AND outcome IN ('completed','accepted')
           AND created_at > now() - interval '6 hours'
    ) THEN
        RETURN 0.4;
    END IF;

    -- Toute interaction dans les 24 h : réduction modérée.
    IF EXISTS (
        SELECT 1 FROM public.match_history
         WHERE user_a = v_a AND user_b = v_b
           AND created_at > now() - interval '24 hours'
    ) THEN
        RETURN 0.6;
    END IF;

    -- Session récente dans les 7 jours : légère réduction.
    IF EXISTS (
        SELECT 1 FROM public.match_history
         WHERE user_a = v_a AND user_b = v_b
           AND outcome = 'completed'
           AND created_at > now() - interval '7 days'
    ) THEN
        RETURN 0.8;
    END IF;

    RETURN 1.0;
END $$;

-- ---------------------------------------------------------------------------
-- 4. RPC : mm_join_queue
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.mm_join_queue(p_client_id TEXT DEFAULT NULL)
RETURNS TABLE(queue_id UUID, expires_at TIMESTAMPTZ, joined BOOLEAN)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_user UUID := auth.uid();
BEGIN
    IF v_user IS NULL THEN
        RAISE EXCEPTION 'unauthorized' USING ERRCODE = '28000';
    END IF;

    -- Profil utilisable ?
    IF NOT EXISTS (
        SELECT 1 FROM public.profiles
         WHERE id = v_user
           AND is_banned = false
           AND moderation_status = 'active'
    ) THEN
        RAISE EXCEPTION 'profile_unavailable' USING ERRCODE = '42704';
    END IF;

    -- Pas déjà engagé dans un appel.
    IF EXISTS (
        SELECT 1 FROM public.calls
         WHERE (caller_id = v_user OR callee_id = v_user)
           AND status IN ('waiting','live')
    ) THEN
        RAISE EXCEPTION 'already_in_call' USING ERRCODE = '23P01';
    END IF;

    INSERT INTO public.matchmaking_queue (user_id, heartbeat_at, expires_at, client_id, retry_count)
    VALUES (v_user, now(), now() + interval '5 minutes', p_client_id, 0)
    ON CONFLICT (user_id) DO UPDATE
        SET heartbeat_at = now(),
            expires_at   = now() + interval '5 minutes',
            client_id    = COALESCE(EXCLUDED.client_id, public.matchmaking_queue.client_id);

    INSERT INTO public.user_presence (user_id, status, updated_at)
    VALUES (v_user, 'searching', now())
    ON CONFLICT (user_id) DO UPDATE
        SET status = 'searching', updated_at = now();

    INSERT INTO public.queue_events (user_id, event, payload)
    VALUES (v_user, 'joined', jsonb_build_object('client_id', p_client_id));

    RETURN QUERY
        SELECT q.id, q.expires_at, true
          FROM public.matchmaking_queue q
         WHERE q.user_id = v_user;
END $$;

-- ---------------------------------------------------------------------------
-- 5. RPC : mm_leave_queue
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.mm_leave_queue()
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_user UUID := auth.uid();
    v_was_in_queue BOOLEAN;
BEGIN
    IF v_user IS NULL THEN
        RAISE EXCEPTION 'unauthorized' USING ERRCODE = '28000';
    END IF;

    DELETE FROM public.matchmaking_queue WHERE user_id = v_user;
    GET DIAGNOSTICS v_was_in_queue = ROW_COUNT;

    UPDATE public.user_presence
       SET status = 'online', updated_at = now()
     WHERE user_id = v_user AND status = 'searching';

    IF v_was_in_queue THEN
        INSERT INTO public.queue_events (user_id, event) VALUES (v_user, 'left');
    END IF;

    RETURN v_was_in_queue;
END $$;

-- ---------------------------------------------------------------------------
-- 6. RPC : mm_heartbeat
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.mm_heartbeat()
RETURNS TABLE(queue_alive BOOLEAN, presence_status TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_user UUID := auth.uid();
    v_alive BOOLEAN := false;
    v_status TEXT := 'offline';
BEGIN
    IF v_user IS NULL THEN
        RAISE EXCEPTION 'unauthorized' USING ERRCODE = '28000';
    END IF;

    UPDATE public.matchmaking_queue
       SET heartbeat_at = now(),
           expires_at   = now() + interval '5 minutes'
     WHERE user_id = v_user
    RETURNING true INTO v_alive;
    v_alive := COALESCE(v_alive, false);

    -- Présence : on respecte un statut 'in_call' déjà en place.
    UPDATE public.user_presence
       SET updated_at = now()
     WHERE user_id = v_user
    RETURNING status INTO v_status;

    IF v_status IS NULL THEN
        -- pas de ligne presence : on crée online par défaut
        INSERT INTO public.user_presence (user_id, status, updated_at)
        VALUES (v_user, 'online', now())
        ON CONFLICT (user_id) DO NOTHING
        RETURNING status INTO v_status;
        v_status := COALESCE(v_status, 'online');
    END IF;

    RETURN QUERY SELECT v_alive, v_status;
END $$;

-- ---------------------------------------------------------------------------
-- 7. RPC : mm_find_match
--   Cœur du moteur : choisit le meilleur peer, réserve atomiquement, crée
--   la session 'waiting'. Toutes les protections de concurrence sont ici.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.mm_find_match(p_min_score INT DEFAULT 40)
RETURNS TABLE(
    matched           BOOLEAN,
    call_id           UUID,
    peer_id           UUID,
    channel_name      TEXT,
    accept_expires_at TIMESTAMPTZ,
    score             INT,
    relaxed           BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_self     UUID := auth.uid();
    v_peer     UUID;
    v_score    NUMERIC;
    v_channel  TEXT;
    v_call     UUID;
    v_deadline TIMESTAMPTZ := now() + interval '12 seconds';
    v_relaxed  BOOLEAN := false;
    v_removed  INT;
BEGIN
    IF v_self IS NULL THEN
        RAISE EXCEPTION 'unauthorized' USING ERRCODE = '28000';
    END IF;

    -- Empêche le même user d'exécuter find_match deux fois en parallèle
    -- (ex. deux devices, ou retry serré côté client).
    PERFORM pg_advisory_xact_lock(hashtextextended('mm_find:' || v_self::text, 0));

    IF NOT EXISTS (SELECT 1 FROM public.matchmaking_queue WHERE user_id = v_self) THEN
        RAISE EXCEPTION 'not_in_queue' USING ERRCODE = '42704';
    END IF;

    IF EXISTS (
        SELECT 1 FROM public.calls
         WHERE (caller_id = v_self OR callee_id = v_self)
           AND status IN ('waiting','live')
    ) THEN
        RAISE EXCEPTION 'already_in_call' USING ERRCODE = '23P01';
    END IF;

    -- ----- Sélection du meilleur candidat ------------------------------------
    WITH self_data AS (
        SELECT  p.id,
                p.gender,
                p.birth_date,
                p.location,
                EXTRACT(YEAR FROM age(p.birth_date))::INT      AS self_age,
                COALESCE(up.seeking_genders, '{}'::text[])     AS self_seek_genders,
                COALESCE(up.seeking_age_min, 18)               AS self_seek_age_min,
                COALESCE(up.seeking_age_max, 120)              AS self_seek_age_max,
                COALESCE(up.max_distance_km, 50)               AS self_max_dist,
                COALESCE(up.languages,  '{}'::text[])          AS self_languages,
                COALESCE(up.interests,  '{}'::text[])          AS self_interests
          FROM public.profiles p
          LEFT JOIN public.user_preferences up ON up.user_id = p.id
         WHERE p.id = v_self
    ),
    cands AS (
        SELECT
            mq.user_id                                                   AS peer_id,
            EXTRACT(YEAR FROM age(p.birth_date))::INT                    AS peer_age,
            ST_Distance(p.location::geography, s.location::geography)    AS dist_m,
            COALESCE(up.languages,  '{}'::text[])                        AS peer_languages,
            COALESCE(up.interests,  '{}'::text[])                        AS peer_interests,
            COALESCE(up.max_distance_km, 50)                             AS peer_max_dist,
            EXTRACT(EPOCH FROM (now() - mq.created_at))                  AS waited_s,
            s.self_age, s.self_max_dist, s.self_languages, s.self_interests
          FROM public.matchmaking_queue mq
          JOIN public.profiles p ON p.id = mq.user_id
          LEFT JOIN public.user_preferences up ON up.user_id = mq.user_id
          CROSS JOIN self_data s
         WHERE mq.user_id <> v_self
           AND mq.expires_at  > now()
           AND mq.heartbeat_at > now() - interval '30 seconds'
           AND p.is_banned = false
           AND p.moderation_status = 'active'
           AND p.location IS NOT NULL
           AND s.location IS NOT NULL
           -- Bilatéral : aucun blocage dans un sens ou l'autre.
           AND NOT EXISTS (
               SELECT 1 FROM public.blocked_users b
                WHERE (b.user_id = v_self AND b.blocked_user_id = mq.user_id)
                   OR (b.user_id = mq.user_id AND b.blocked_user_id = v_self)
           )
           -- Compatibilité de genre bidirectionnelle.
           AND (cardinality(s.self_seek_genders) = 0 OR p.gender = ANY(s.self_seek_genders))
           AND (COALESCE(cardinality(up.seeking_genders), 0) = 0
                OR s.gender = ANY(up.seeking_genders))
           -- Compatibilité d'âge bidirectionnelle.
           AND EXTRACT(YEAR FROM age(p.birth_date))::INT
                 BETWEEN s.self_seek_age_min AND s.self_seek_age_max
           AND s.self_age
                 BETWEEN COALESCE(up.seeking_age_min, 18)
                     AND COALESCE(up.seeking_age_max, 120)
           -- Distance bilatérale : on prend le plus restrictif des deux rayons.
           AND ST_Distance(p.location::geography, s.location::geography)
                 <= LEAST(s.self_max_dist, COALESCE(up.max_distance_km, 50)) * 1000
    ),
    scored AS (
        SELECT
            c.peer_id,
            40 * (1 - LEAST(1.0,
                            c.dist_m / NULLIF(LEAST(c.self_max_dist, c.peer_max_dist) * 1000, 0)
                       ))                                              AS sc_dist,
            15 * public.mm_jaccard(c.self_languages, c.peer_languages) AS sc_lang,
            20 * public.mm_jaccard(c.self_interests, c.peer_interests) AS sc_int,
            10 * (1 - LEAST(1.0, ABS(c.self_age - c.peer_age) / 15.0)) AS sc_age,
            15 * GREATEST(0, 1 - c.waited_s / 600.0)                   AS sc_fresh
          FROM cands c
    ),
    with_total AS (
        SELECT  peer_id,
                (sc_dist + sc_lang + sc_int + sc_age + sc_fresh)
                  * public.mm_history_penalty(v_self, peer_id) AS final_score
          FROM scored
    )
    SELECT peer_id, final_score
      INTO v_peer, v_score
      FROM with_total
     ORDER BY final_score DESC NULLS LAST, peer_id
     LIMIT 1;

    -- Pas de candidat compatible du tout : on sort proprement.
    IF v_peer IS NULL THEN
        RETURN QUERY SELECT false, NULL::UUID, NULL::UUID, NULL::TEXT,
                            NULL::TIMESTAMPTZ, NULL::INT, false;
        RETURN;
    END IF;

    -- Sous le seuil demandé : on relaxe à 20 si possible, sinon on sort.
    IF v_score < p_min_score THEN
        IF v_score >= 20 THEN
            v_relaxed := true;
        ELSE
            RETURN QUERY SELECT false, NULL::UUID, NULL::UUID, NULL::TEXT,
                                NULL::TIMESTAMPTZ, NULL::INT, false;
            RETURN;
        END IF;
    END IF;

    -- ----- Réservation atomique du couple ------------------------------------
    -- FOR UPDATE SKIP LOCKED : si un autre mm_find_match concurrent verrouille
    -- déjà l'un des deux peers, on échoue avec 'peer_taken'.
    WITH locked AS (
        SELECT user_id FROM public.matchmaking_queue
         WHERE user_id IN (v_self, v_peer)
         FOR UPDATE SKIP LOCKED
    ),
    removed AS (
        DELETE FROM public.matchmaking_queue
         WHERE user_id IN (SELECT user_id FROM locked)
        RETURNING user_id
    )
    SELECT count(*) INTO v_removed FROM removed;

    IF v_removed <> 2 THEN
        -- l'un des deux a été pris par un finder concurrent
        RAISE EXCEPTION 'peer_taken' USING ERRCODE = '23P01';
    END IF;

    v_channel := 'dn_' || encode(gen_random_bytes(16), 'hex');

    INSERT INTO public.calls
        (caller_id, callee_id, status, channel_name, started_at,
         accept_expires_at, room_expires_at)
    VALUES
        (v_self, v_peer, 'waiting', v_channel, now(),
         v_deadline, now() + interval '30 minutes')
    RETURNING id INTO v_call;

    INSERT INTO public.match_history (user_a, user_b, call_id, outcome, metadata)
    VALUES (LEAST(v_self, v_peer), GREATEST(v_self, v_peer), v_call, 'proposed',
            jsonb_build_object('score', round(v_score), 'relaxed', v_relaxed));

    INSERT INTO public.queue_events (user_id, event, payload) VALUES
        (v_self, 'matched', jsonb_build_object(
            'peer', v_peer, 'call_id', v_call,
            'score', round(v_score), 'relaxed', v_relaxed
        )),
        (v_peer, 'matched', jsonb_build_object(
            'peer', v_self, 'call_id', v_call,
            'score', round(v_score), 'relaxed', v_relaxed
        ));

    UPDATE public.user_presence
       SET status = 'in_call', updated_at = now()
     WHERE user_id IN (v_self, v_peer);

    RETURN QUERY SELECT true, v_call, v_peer, v_channel,
                        v_deadline, round(v_score)::INT, v_relaxed;
END $$;

-- ---------------------------------------------------------------------------
-- 8. RPC : mm_accept_match
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.mm_accept_match(p_call_id UUID)
RETURNS TABLE(state TEXT, both_ready BOOLEAN, channel_name TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_self    UUID := auth.uid();
    v_caller  UUID;
    v_callee  UUID;
    v_status  TEXT;
    v_deadline TIMESTAMPTZ;
    v_cready  BOOLEAN;
    v_eready  BOOLEAN;
    v_channel TEXT;
BEGIN
    IF v_self IS NULL THEN
        RAISE EXCEPTION 'unauthorized' USING ERRCODE = '28000';
    END IF;

    -- Verrou ligne pour éviter une race entre les deux ready.
    SELECT caller_id, callee_id, status, accept_expires_at,
           caller_ready, callee_ready, channel_name
      INTO v_caller, v_callee, v_status, v_deadline,
           v_cready, v_eready, v_channel
      FROM public.calls
     WHERE id = p_call_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'call_not_found' USING ERRCODE = '42704';
    END IF;
    IF v_self NOT IN (v_caller, v_callee) THEN
        RAISE EXCEPTION 'not_a_participant' USING ERRCODE = '42501';
    END IF;
    IF v_status <> 'waiting' THEN
        RAISE EXCEPTION 'call_not_waiting' USING ERRCODE = '23P01';
    END IF;
    IF v_deadline IS NOT NULL AND v_deadline < now() THEN
        RAISE EXCEPTION 'accept_window_expired' USING ERRCODE = '23P01';
    END IF;

    IF v_self = v_caller THEN
        v_cready := true;
    ELSE
        v_eready := true;
    END IF;

    UPDATE public.calls
       SET caller_ready = v_cready,
           callee_ready = v_eready,
           status = CASE WHEN v_cready AND v_eready THEN 'live' ELSE 'waiting' END,
           room_expires_at = CASE
                WHEN v_cready AND v_eready
                THEN COALESCE(room_expires_at, now() + interval '30 minutes')
                ELSE room_expires_at
           END
     WHERE id = p_call_id;

    IF v_cready AND v_eready THEN
        INSERT INTO public.match_history (user_a, user_b, call_id, outcome)
        VALUES (LEAST(v_caller, v_callee), GREATEST(v_caller, v_callee),
                p_call_id, 'accepted')
        ON CONFLICT DO NOTHING;
    END IF;

    RETURN QUERY
        SELECT CASE WHEN v_cready AND v_eready THEN 'live' ELSE 'waiting' END,
               (v_cready AND v_eready),
               v_channel;
END $$;

-- ---------------------------------------------------------------------------
-- 9. RPC : mm_decline_match
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.mm_decline_match(p_call_id UUID, p_reason TEXT DEFAULT NULL)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_self    UUID := auth.uid();
    v_caller  UUID;
    v_callee  UUID;
    v_status  TEXT;
    v_other   UUID;
BEGIN
    IF v_self IS NULL THEN
        RAISE EXCEPTION 'unauthorized' USING ERRCODE = '28000';
    END IF;

    SELECT caller_id, callee_id, status INTO v_caller, v_callee, v_status
      FROM public.calls
     WHERE id = p_call_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'call_not_found' USING ERRCODE = '42704';
    END IF;
    IF v_self NOT IN (v_caller, v_callee) THEN
        RAISE EXCEPTION 'not_a_participant' USING ERRCODE = '42501';
    END IF;
    IF v_status <> 'waiting' THEN
        -- déjà live ou ended : decline n'a plus de sens
        RETURN false;
    END IF;

    v_other := CASE WHEN v_self = v_caller THEN v_callee ELSE v_caller END;

    UPDATE public.calls
       SET status     = 'ended',
           ended_at   = now(),
           ended_by   = v_self,
           end_reason = 'declined'
     WHERE id = p_call_id;

    INSERT INTO public.match_history (user_a, user_b, call_id, outcome, metadata)
    VALUES (LEAST(v_caller, v_callee), GREATEST(v_caller, v_callee),
            p_call_id, 'declined',
            jsonb_build_object('declined_by', v_self, 'reason', p_reason));

    INSERT INTO public.queue_events (user_id, event, payload) VALUES
        (v_self,  'declined', jsonb_build_object('peer', v_other, 'call_id', p_call_id, 'reason', p_reason)),
        (v_other, 'declined', jsonb_build_object('peer', v_self,  'call_id', p_call_id, 'reason', p_reason));

    -- Le déclineur sort de la file ; l'autre est ré-injecté.
    DELETE FROM public.matchmaking_queue WHERE user_id IN (v_self, v_other);

    UPDATE public.user_presence
       SET status = 'online', updated_at = now()
     WHERE user_id = v_self;

    INSERT INTO public.matchmaking_queue (user_id, heartbeat_at, expires_at, retry_count)
    VALUES (v_other, now(), now() + interval '5 minutes', 0)
    ON CONFLICT (user_id) DO UPDATE
        SET heartbeat_at = now(),
            expires_at   = now() + interval '5 minutes';

    UPDATE public.user_presence
       SET status = 'searching', updated_at = now()
     WHERE user_id = v_other;

    RETURN true;
END $$;

-- ---------------------------------------------------------------------------
-- 10. RPC : mm_cancel_session (hangup en cours de session live)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.mm_cancel_session(p_call_id UUID, p_reason TEXT DEFAULT 'user_cancel')
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_self    UUID := auth.uid();
    v_caller  UUID;
    v_callee  UUID;
    v_status  TEXT;
    v_reason  TEXT := COALESCE(p_reason, 'user_cancel');
BEGIN
    IF v_self IS NULL THEN
        RAISE EXCEPTION 'unauthorized' USING ERRCODE = '28000';
    END IF;
    IF v_reason NOT IN ('user_cancel','normal_end','cancelled') THEN
        v_reason := 'user_cancel';
    END IF;

    SELECT caller_id, callee_id, status INTO v_caller, v_callee, v_status
      FROM public.calls
     WHERE id = p_call_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'call_not_found' USING ERRCODE = '42704';
    END IF;
    IF v_self NOT IN (v_caller, v_callee) THEN
        RAISE EXCEPTION 'not_a_participant' USING ERRCODE = '42501';
    END IF;
    IF v_status = 'ended' THEN
        RETURN false; -- déjà terminée
    END IF;

    UPDATE public.calls
       SET status     = 'ended',
           ended_at   = now(),
           ended_by   = v_self,
           end_reason = v_reason,
           duration_seconds = GREATEST(0, EXTRACT(EPOCH FROM (now() - started_at))::INT)
     WHERE id = p_call_id;

    INSERT INTO public.match_history (user_a, user_b, call_id, outcome, metadata)
    VALUES (LEAST(v_caller, v_callee), GREATEST(v_caller, v_callee), p_call_id,
            CASE WHEN v_reason = 'normal_end' THEN 'completed' ELSE 'cancelled' END,
            jsonb_build_object('ended_by', v_self, 'reason', v_reason));

    UPDATE public.user_presence
       SET status = 'online', updated_at = now()
     WHERE user_id IN (v_caller, v_callee);

    RETURN true;
END $$;

-- ---------------------------------------------------------------------------
-- 11. RPC : mm_sweep_timeouts (cron)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.mm_sweep_timeouts()
RETURNS TABLE(
    queue_expired         INT,
    calls_accept_timeout  INT,
    calls_room_timeout    INT,
    calls_ghost           INT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_queue_expired  INT := 0;
    v_accept_timeout INT := 0;
    v_room_timeout   INT := 0;
    v_ghost          INT := 0;
BEGIN
    -- a) Entrées de queue expirées (TTL ou heartbeat stale).
    WITH expired AS (
        DELETE FROM public.matchmaking_queue
         WHERE expires_at < now()
            OR heartbeat_at < now() - interval '30 seconds'
        RETURNING user_id
    )
    INSERT INTO public.queue_events (user_id, event)
    SELECT user_id, 'expired' FROM expired;
    GET DIAGNOSTICS v_queue_expired = ROW_COUNT;

    -- Présence à 'online' si on les a sortis de queue
    UPDATE public.user_presence pres
       SET status = 'online', updated_at = now()
      FROM public.queue_events qe
     WHERE qe.event = 'expired'
       AND qe.created_at > now() - interval '5 seconds'
       AND pres.user_id = qe.user_id
       AND pres.status  = 'searching';

    -- b) Calls 'waiting' avec accept_expires_at dépassé.
    WITH timed AS (
        UPDATE public.calls
           SET status = 'ended',
               ended_at = now(),
               end_reason = 'accept_timeout'
         WHERE status = 'waiting'
           AND accept_expires_at IS NOT NULL
           AND accept_expires_at < now()
        RETURNING id, caller_id, callee_id, caller_ready, callee_ready
    ),
    history AS (
        INSERT INTO public.match_history (user_a, user_b, call_id, outcome, metadata)
        SELECT LEAST(caller_id, callee_id),
               GREATEST(caller_id, callee_id),
               id,
               'timed_out',
               jsonb_build_object('caller_ready', caller_ready, 'callee_ready', callee_ready)
          FROM timed
        RETURNING 1
    ),
    -- Ré-injection du user qui avait accepté
    requeue AS (
        INSERT INTO public.matchmaking_queue (user_id, heartbeat_at, expires_at, retry_count)
        SELECT CASE
                   WHEN caller_ready AND NOT callee_ready THEN caller_id
                   WHEN callee_ready AND NOT caller_ready THEN callee_id
               END,
               now(),
               now() + interval '5 minutes',
               1
          FROM timed
         WHERE (caller_ready AND NOT callee_ready)
            OR (callee_ready AND NOT caller_ready)
        ON CONFLICT (user_id) DO UPDATE
            SET heartbeat_at = now(),
                expires_at   = now() + interval '5 minutes',
                retry_count  = public.matchmaking_queue.retry_count + 1
        RETURNING user_id
    )
    SELECT count(*) INTO v_accept_timeout FROM timed;

    -- Mettre la présence à 'searching' pour les ré-injectés, 'online' pour l'autre.
    UPDATE public.user_presence pres
       SET status = 'searching', updated_at = now()
      FROM public.matchmaking_queue mq
     WHERE mq.user_id = pres.user_id
       AND pres.status <> 'searching';

    -- c) Calls 'live' avec room_expires_at dépassé.
    WITH expired AS (
        UPDATE public.calls
           SET status     = 'ended',
               ended_at   = now(),
               end_reason = 'room_timeout',
               duration_seconds = GREATEST(0, EXTRACT(EPOCH FROM (now() - started_at))::INT)
         WHERE status = 'live'
           AND room_expires_at IS NOT NULL
           AND room_expires_at < now()
        RETURNING id, caller_id, callee_id
    )
    INSERT INTO public.match_history (user_a, user_b, call_id, outcome, metadata)
    SELECT LEAST(caller_id, callee_id), GREATEST(caller_id, callee_id),
           id, 'completed', jsonb_build_object('reason', 'room_timeout')
      FROM expired;
    GET DIAGNOSTICS v_room_timeout = ROW_COUNT;

    -- d) Calls 'live' fantômes : aucun heartbeat des deux participants
    --    (présence pas mise à jour depuis 60s) ⇒ on coupe.
    WITH ghosts AS (
        UPDATE public.calls c
           SET status     = 'ended',
               ended_at   = now(),
               end_reason = 'ghost',
               duration_seconds = GREATEST(0, EXTRACT(EPOCH FROM (now() - started_at))::INT)
         WHERE c.status = 'live'
           AND NOT EXISTS (
               SELECT 1 FROM public.user_presence up
                WHERE up.user_id IN (c.caller_id, c.callee_id)
                  AND up.updated_at > now() - interval '60 seconds'
           )
        RETURNING id, caller_id, callee_id
    )
    INSERT INTO public.match_history (user_a, user_b, call_id, outcome, metadata)
    SELECT LEAST(caller_id, callee_id), GREATEST(caller_id, callee_id),
           id, 'cancelled', jsonb_build_object('reason', 'ghost')
      FROM ghosts;
    GET DIAGNOSTICS v_ghost = ROW_COUNT;

    RETURN QUERY SELECT v_queue_expired, v_accept_timeout, v_room_timeout, v_ghost;
END $$;

-- ---------------------------------------------------------------------------
-- 12. Purge des events anciens (> 30j) — appelée occasionnellement
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.mm_purge_old_events()
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_count INT;
BEGIN
    DELETE FROM public.queue_events
     WHERE created_at < now() - interval '30 days';
    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END $$;

-- ---------------------------------------------------------------------------
-- 13. Permissions d'exécution
-- ---------------------------------------------------------------------------
-- Toutes les fonctions utilisateur exigent auth.uid() en tête : on peut donc
-- les exposer aux roles 'authenticated' sans risque.
GRANT EXECUTE ON FUNCTION public.mm_join_queue(TEXT)              TO authenticated;
GRANT EXECUTE ON FUNCTION public.mm_leave_queue()                 TO authenticated;
GRANT EXECUTE ON FUNCTION public.mm_heartbeat()                   TO authenticated;
GRANT EXECUTE ON FUNCTION public.mm_find_match(INT)               TO authenticated;
GRANT EXECUTE ON FUNCTION public.mm_accept_match(UUID)            TO authenticated;
GRANT EXECUTE ON FUNCTION public.mm_decline_match(UUID, TEXT)     TO authenticated;
GRANT EXECUTE ON FUNCTION public.mm_cancel_session(UUID, TEXT)    TO authenticated;

-- Sweep : service_role uniquement (jamais appelable depuis le client).
REVOKE EXECUTE ON FUNCTION public.mm_sweep_timeouts() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.mm_purge_old_events() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.mm_sweep_timeouts() TO service_role;
GRANT  EXECUTE ON FUNCTION public.mm_purge_old_events() TO service_role;

-- ---------------------------------------------------------------------------
-- 14. pg_cron : sweep toutes les minutes (idempotent)
--   Note : Supabase active pg_cron sur demande (dashboard) ; ce bloc ne
--   plantera pas si l'extension est absente.
-- ---------------------------------------------------------------------------
DO $cron$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
        -- supprime l'ancien job s'il existe
        PERFORM cron.unschedule(j.jobid)
          FROM cron.job j
         WHERE j.jobname = 'mm_sweep_timeouts';

        PERFORM cron.schedule(
            'mm_sweep_timeouts',
            '* * * * *',                    -- toutes les minutes
            $sql$SELECT public.mm_sweep_timeouts();$sql$
        );

        PERFORM cron.unschedule(j.jobid)
          FROM cron.job j
         WHERE j.jobname = 'mm_purge_old_events';

        PERFORM cron.schedule(
            'mm_purge_old_events',
            '15 3 * * *',                   -- chaque jour à 03:15
            $sql$SELECT public.mm_purge_old_events();$sql$
        );
    END IF;
END $cron$;

COMMIT;
