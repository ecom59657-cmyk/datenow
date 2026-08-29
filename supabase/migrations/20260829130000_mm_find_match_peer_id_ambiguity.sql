-- =============================================================================
-- DateNow — mm_find_match : lever l'ambiguïté sur `peer_id`
--
-- `mm_find_match` échouait à CHAQUE appel, en production, depuis
-- 20260528120000_matching_engine_v2.sql :
--
--   FunctionException(status: 500, {error: internal_error,
--     message: column reference "peer_id" is ambiguous})
--
-- `peer_id` est à la fois une colonne du `RETURNS TABLE` — donc une variable
-- plpgsql — et la colonne des CTE `scored` / `with_total`. Les références non
-- qualifiées du bloc `with_total` et du SELECT final laissaient plpgsql
-- incapable de trancher : erreur 42702 à l'exécution, systématique.
--
-- Personne ne l'a vue parce que le client la rattrape : `FallbackMatchingDriver`
-- bascule silencieusement sur V1 et le date part quand même. `MATCHING_V2=true`
-- est en production depuis des mois sans que V2 ait jamais matché une seule
-- fois. Constaté sur device le 2026-08-29, logs `[MATCHING V2][WARN]`.
--
-- Correction : qualifier les références (`sco.` sur `scored`, `wt.` sur
-- `with_total`). Aucune pondération, aucun filtre, aucun seuil ne change —
-- la fonction est reprise en patchant son texte, pas en la retapant.
--
-- ⚠️ Effet produit : en réparant V2, c'est V2 qui matche à partir de
-- maintenant, avec ses pondérations serveur (distance 34 / intérêts 17 /
-- intentions 13 / âge 9 / fraîcheur 13 + background), et non plus V1.
-- C'était l'intention d'origine de `MATCHING_V2=true`.
-- =============================================================================

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
                COALESCE(up.interests,  '{}'::text[])          AS self_interests,
                COALESCE(ub.origins, '{}'::text[])             AS self_origins,
                ub.religion                                    AS self_religion,
                ub.drinking                                    AS self_drinking,
                ub.smoking                                     AS self_smoking,
                ub.education                                   AS self_education,
                COALESCE(ub.match_on_origins,  false)          AS self_ok_origins,
                COALESCE(ub.match_on_religion, false)          AS self_ok_religion
          FROM public.profiles p
          LEFT JOIN public.user_preferences up ON up.user_id = p.id
          LEFT JOIN public.user_background  ub ON ub.user_id = p.id
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
            COALESCE(pb.origins, '{}'::text[])                           AS peer_origins,
            pb.religion                                                  AS peer_religion,
            pb.drinking                                                  AS peer_drinking,
            pb.smoking                                                   AS peer_smoking,
            pb.education                                                 AS peer_education,
            COALESCE(pb.match_on_origins,  false)                        AS peer_ok_origins,
            COALESCE(pb.match_on_religion, false)                        AS peer_ok_religion,
            s.self_age, s.self_max_dist, s.self_intentions, s.self_interests,
            s.self_origins, s.self_religion, s.self_drinking, s.self_smoking,
            s.self_education, s.self_ok_origins, s.self_ok_religion
          FROM public.matchmaking_queue mq
          JOIN public.profiles p ON p.id = mq.user_id
          LEFT JOIN public.user_preferences up ON up.user_id = mq.user_id
          LEFT JOIN public.user_background  pb ON pb.user_id = mq.user_id
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
    -- Les cinq axes historiques gardent leurs proportions relatives, ramenés
    -- de 100 à 86 pour laisser 14 points aux deux axes de background.
    -- Distance 40→34, intérêts 20→17, intentions 15→13, âge 10→9,
    -- fraîcheur 15→13.
    scored AS (
        SELECT
            c.peer_id,
            34 * (1 - LEAST(1.0,
                            c.dist_m / NULLIF(LEAST(c.self_max_dist, c.peer_max_dist) * 1000, 0)
                       ))                                              AS sc_dist,
            13 * public.mm_jaccard(c.self_intentions, c.peer_intentions)
                                                                       AS sc_intent,
            17 * public.mm_jaccard(c.self_interests, c.peer_interests) AS sc_int,
             9 * (1 - LEAST(1.0, ABS(c.self_age - c.peer_age) / 15.0)) AS sc_age,
            13 * GREATEST(0, 1 - c.waited_s / 600.0)                   AS sc_fresh,
            public.mm_lifestyle_score(
              c.self_drinking, c.peer_drinking,
              c.self_smoking,  c.peer_smoking,
              c.self_education, c.peer_education)                      AS r_life,
            public.mm_affinity_score(
              c.self_origins, c.peer_origins,
              c.self_religion, c.peer_religion,
              c.self_ok_origins,  c.peer_ok_origins,
              c.self_ok_religion, c.peer_ok_religion)                  AS r_aff
          FROM cands c
    ),
    -- Un axe absent sort du dénominateur, il ne vaut pas zéro. Noter un zéro
    -- reviendrait à facturer un refus de consentement, et un consentement
    -- qu'on paie n'est plus libre.
    with_total AS (
        SELECT  sco.peer_id,
                (
                  (sco.sc_dist + sco.sc_intent + sco.sc_int + sco.sc_age
                   + sco.sc_fresh
                   + COALESCE(8 * sco.r_life, 0)
                   + COALESCE(6 * sco.r_aff,  0))
                  * 100.0
                  / (86 + CASE WHEN sco.r_life IS NULL THEN 0 ELSE 8 END
                        + CASE WHEN sco.r_aff  IS NULL THEN 0 ELSE 6 END)
                ) * public.mm_history_penalty(v_self, sco.peer_id) AS final_score
          FROM scored sco
    )
    SELECT wt.peer_id, wt.final_score
      INTO v_peer, v_score
      FROM with_total wt
     ORDER BY wt.final_score DESC NULLS LAST, wt.peer_id
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
