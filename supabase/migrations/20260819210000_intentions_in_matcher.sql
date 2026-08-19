-- -----------------------------------------------------------------------------
-- Intentions enter the live matcher
-- -----------------------------------------------------------------------------
-- `MatchingService` (Dart) treats intentions as the single best predictor of a
-- good call: 30 of its 100 points, plus a hard gate. Neither server engine
-- knew the field existed. Since MATCHING_V2=true, the engine that actually
-- decides real calls is `mm_find_match` — so someone looking for something
-- serious could be put on a five-minute video date with someone looking for
-- something casual, and neither can leave gracefully once it starts.
--
-- Two changes, and the weight for the second one was already lying around.
--
-- 1. A hard gate on the unambiguous opposition only — one side exclusively
--    `serious`, the other exclusively `casual`. Gating any wider empties the
--    pool at launch volume, which is why `MatchingService.intentionsCompatible`
--    draws the line there too. This migration mirrors it exactly, in a pure
--    function so the rule can be tested on its own rather than only through a
--    matcher that needs a queue, two live heartbeats and PostGIS to run.
--
-- 2. A soft axis worth 15 points, taken from the languages axis rather than
--    from any live weight. That axis was dead: `user_preferences.languages`
--    exists with `DEFAULT '{}'`, no Dart code has ever written it, and
--    `mm_jaccard` of two empty arrays returns 0. Every pair lost the same 15
--    points, so the engine has been scoring out of 85 while comparing against
--    a floor expressed out of 100. Removing it is not a trade-off, it is the
--    same defect as the orientation axis deleted earlier: a whole weight that
--    discriminated nothing.
--
-- Net effect on the scale: distance 40, intentions 15, interests 20, age 10,
-- freshness 15 — a real 100 again.
--
-- Values are the Dart enum `.name`: serious, feeling, talk, casual.
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- mm_intentions_compatible — the rule, on its own
-- -----------------------------------------------------------------------------
-- Mirrors MatchingService.intentionsCompatible line for line:
--
--   * either side silent  -> compatible. Absence of an answer is not an
--     opposition, and gating on it would punish incomplete profiles;
--   * any overlap         -> compatible;
--   * otherwise, refuse only serious-alone against casual-alone.
--
-- `feeling` and `talk` never block anything, in any combination. That is
-- deliberate: they are the middle of the range, and a pool this small cannot
-- afford a stricter reading.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.mm_intentions_compatible(a TEXT[], b TEXT[])
RETURNS BOOLEAN
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $fn$
    SELECT CASE
        WHEN a IS NULL OR b IS NULL
          OR cardinality(a) = 0 OR cardinality(b) = 0 THEN TRUE
        WHEN EXISTS (
            SELECT 1 FROM unnest(a) AS t(v) WHERE t.v = ANY(b)
        ) THEN TRUE
        ELSE NOT (
            (a = ARRAY['serious']::TEXT[] AND b = ARRAY['casual']::TEXT[])
         OR (a = ARRAY['casual']::TEXT[]  AND b = ARRAY['serious']::TEXT[])
        )
    END;
$fn$;

COMMENT ON FUNCTION public.mm_intentions_compatible(TEXT[], TEXT[]) IS
  'Hard gate on intentions: refuses only serious-alone vs casual-alone. '
  'Mirrors MatchingService.intentionsCompatible in Dart.';

-- -----------------------------------------------------------------------------
-- mm_find_match — same function, with the two changes above
-- -----------------------------------------------------------------------------
-- Reproduced from 20260528120000_matching_engine_v2.sql by patching its text,
-- not by retyping it: everything not mentioned in the header above is
-- byte-for-byte the previous definition.
-- -----------------------------------------------------------------------------

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
                COALESCE(up.intentions, '{}'::text[])          AS self_intentions,
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
            COALESCE(up.intentions, '{}'::text[])                        AS peer_intentions,
            COALESCE(up.interests,  '{}'::text[])                        AS peer_interests,
            COALESCE(up.max_distance_km, 50)                             AS peer_max_dist,
            EXTRACT(EPOCH FROM (now() - mq.created_at))                  AS waited_s,
            s.self_age, s.self_max_dist, s.self_intentions, s.self_interests
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
           -- Opposition franche des intentions : cinq minutes de vidéo en
           -- direct coûtent trop cher pour être dépensées sur un « sérieux »
           -- contre un « léger », et personne ne peut partir élégamment une
           -- fois l'appel commencé. Même règle que MatchingService.
           AND public.mm_intentions_compatible(
                 s.self_intentions,
                 COALESCE(up.intentions, '{}'::text[])
               )
    ),
    scored AS (
        SELECT
            c.peer_id,
            40 * (1 - LEAST(1.0,
                            c.dist_m / NULLIF(LEAST(c.self_max_dist, c.peer_max_dist) * 1000, 0)
                       ))                                              AS sc_dist,
            15 * public.mm_jaccard(c.self_intentions, c.peer_intentions)
                                                                       AS sc_intent,
            20 * public.mm_jaccard(c.self_interests, c.peer_interests) AS sc_int,
            10 * (1 - LEAST(1.0, ABS(c.self_age - c.peer_age) / 15.0)) AS sc_age,
            15 * GREATEST(0, 1 - c.waited_s / 600.0)                   AS sc_fresh
          FROM cands c
    ),
    with_total AS (
        SELECT  peer_id,
                (sc_dist + sc_intent + sc_int + sc_age + sc_fresh)
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

NOTIFY pgrst, 'reload schema';
