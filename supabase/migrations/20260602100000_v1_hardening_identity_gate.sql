-- =============================================================================
-- DateNow — V1 Hardening Sprint, Commit 1 : Server-side identity gate
--
-- Adds a server-side identity check to `mm_join_queue` and
-- `mm_find_match`. Until this commit, the only place enforcing
-- "user must be identity-verified before launching a date" was the
-- Flutter Find-date button (commit fdfb279). An authenticated user
-- that bypassed the client (forged JWT, curl, tampered build) could
-- enter the matchmaking queue without ever having gone through the
-- Didit KYC. Pass 1 / Pass 7 of the security audit flagged this as
-- a BLOCKER (P1.1 / A1_FIND_BYPASS).
--
-- The check is LENIENT on purpose : it accepts both real Didit-
-- approved accounts AND legacy `grandfather` accounts from the
-- Phase 1 migration. This matches the runtime behaviour of
-- `FeatureFlags.requireIdentityVerification` + the
-- `has_verified_identity()` RPC :
--
--     identity_verified = TRUE  AND  age_verified = TRUE
--
-- Strict Didit-only enforcement (i.e. also requiring
-- identity_provider = 'didit') stays a UX layer concern handled by
-- `isDiditVerifiedProvider` on the client. Server-side we want to
-- keep grandfather accounts working until they ALL re-verify
-- through Didit, otherwise the dev team loses access to matching
-- the moment this migration applies — and any user on a
-- 0.1.0+37 client without the new strict gate would be silently
-- locked out, which is worse than the bypass we are closing here.
--
-- Migration safety :
--   - Pure CREATE OR REPLACE of two existing functions ; no data
--     migration, no schema change, no RLS change.
--   - Bodies copied VERBATIM from
--     20260528120000_matching_engine_v2.sql ; only the new check
--     block is inserted at the top of each function.
--   - Rollback : re-run the relevant CREATE OR REPLACE blocks from
--     20260528120000 and the functions revert to the pre-hardening
--     bodies.
-- =============================================================================

-- ── mm_join_queue (re-created with identity gate) ────────────────
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

    -- V1 HARDENING (Pass 1 / Pass 7 — P1.1 / A1_FIND_BYPASS).
    -- Block unverified users at the server layer ; the client-side
    -- Phase 5 gate is no longer the only line of defence.
    -- Lenient : grandfather accounts pass too (see header doc).
    IF NOT EXISTS (
        SELECT 1 FROM public.profiles
         WHERE id = v_user
           AND identity_verified = true
           AND age_verified      = true
    ) THEN
        RAISE EXCEPTION 'identity_required' USING ERRCODE = '42501';
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

-- ── mm_find_match (re-created with identity gate) ────────────────
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

    -- V1 HARDENING (Pass 1 / Pass 7 — P1.1 / A1_FIND_BYPASS).
    -- Second line of defence : even if a tampered client somehow
    -- bypassed mm_join_queue (or the queue row was inserted via a
    -- direct REST write before the policy hardening in commit 4),
    -- mm_find_match also refuses to act for an unverified caller.
    IF NOT EXISTS (
        SELECT 1 FROM public.profiles
         WHERE id = v_self
           AND identity_verified = true
           AND age_verified      = true
    ) THEN
        RAISE EXCEPTION 'identity_required' USING ERRCODE = '42501';
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

-- =============================================================================
-- After this migration applies :
--   - calling mm_join_queue / mm_find_match without identity_verified=true
--     AND age_verified=true on the caller's profile raises 42501
--     'identity_required',
--   - grandfather accounts (Phase 1 migration leftovers) keep working :
--     their identity_verified + age_verified are true, just with
--     identity_provider='grandfather',
--   - the Edge Functions (join-queue, find-match) need no change —
--     their error mappers will translate SQLSTATE 42501 to a 403 with
--     code 'identity_required' that the Dart layer can surface as the
--     existing "Vérification d'identité requise" modal,
--   - no Dart change required for this commit.
-- =============================================================================
