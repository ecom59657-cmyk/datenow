-- =============================================================================
-- DateNow — the background answers finally reach the matcher
--
-- Five questions were collected at signup — origins, religion, drinking,
-- smoking, education — and used nowhere: not in the SQL matcher, not in the
-- Dart score, not even displayed. Collecting article 9 data for no purpose is
-- the one thing data minimisation forbids outright, so the choice was to
-- either drop them or give them a purpose. This is the second.
--
-- Two axes, deliberately not the same kind of thing:
--
--   lifestyle  drinking, smoking, education. Ordinary personal data. Weighs
--              as soon as both sides answered — being brought closer to a
--              non-smoker is not a decision about who someone is.
--
--   affinity   origins and religion. Article 9. Weighs ONLY when BOTH people
--              explicitly asked to be matched on that field. One-sided
--              consent is not enough: weighing someone's belief because the
--              other person cares would process it for a purpose they never
--              agreed to.
--
-- Declining costs nothing. An absent axis is removed from the denominator
-- rather than scored zero — the same treatment an unknown distance already
-- gets. An axis that scored zero for the people who said no would turn a free
-- choice into a penalty, and consent bought that way is not freely given.
--
-- Mirrors MatchingService in Dart, which carries the same rule and the same
-- shape. test/background_matching_test.dart pins the Dart half.
-- =============================================================================

-- ── Consent lives next to the answer it governs ──────────────────────
ALTER TABLE public.user_background
  ADD COLUMN IF NOT EXISTS match_on_origins  BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS match_on_religion BOOLEAN NOT NULL DEFAULT false;

COMMENT ON COLUMN public.user_background.match_on_origins IS
  'Explicit article 9 consent to weigh origins in matching. Defaults to '
  'false: answering the question is not agreeing to be matched on it. '
  'Existing rows keep false — data gathered under a notice that named no '
  'purpose cannot be repurposed.';

COMMENT ON COLUMN public.user_background.match_on_religion IS
  'Explicit article 9 consent to weigh religious belief in matching. Same '
  'default and the same reason.';

-- ── Ordinal closeness — 1 for the same rung, decaying with the gap ───
CREATE OR REPLACE FUNCTION public.mm_ordinal_closeness(
  p_i INT, p_j INT, p_levels INT
)
RETURNS NUMERIC
LANGUAGE sql
IMMUTABLE
SET search_path = public
AS $$
  SELECT CASE
    WHEN p_i IS NULL OR p_j IS NULL OR p_levels <= 1 THEN NULL
    ELSE 1 - ABS(p_i - p_j)::numeric / (p_levels - 1)
  END;
$$;

-- ── lifestyle: average over the fields BOTH sides answered ───────────
--
-- NULL when they share no answered field, so the caller can drop the axis
-- instead of reading a zero that means "unknown".
CREATE OR REPLACE FUNCTION public.mm_lifestyle_score(
  a_drinking TEXT, b_drinking TEXT,
  a_smoking  TEXT, b_smoking  TEXT,
  a_education TEXT, b_education TEXT
)
RETURNS NUMERIC
LANGUAGE plpgsql
IMMUTABLE
SET search_path = public
AS $$
DECLARE
  drink_levels CONSTANT TEXT[] := ARRAY['never','socially','often'];
  smoke_levels CONSTANT TEXT[] := ARRAY['never','occasionally','regularly'];
  -- 'other' sits outside the ladder on purpose: it matches itself and
  -- nothing else rather than pretending to be a rung between two degrees.
  edu_levels   CONSTANT TEXT[] :=
    ARRAY['highSchool','vocational','bachelor','master','doctorate'];
  parts NUMERIC[] := '{}';
  v NUMERIC;
BEGIN
  IF a_drinking IS NOT NULL AND b_drinking IS NOT NULL THEN
    parts := parts || public.mm_ordinal_closeness(
      array_position(drink_levels, a_drinking),
      array_position(drink_levels, b_drinking),
      array_length(drink_levels, 1));
  END IF;

  IF a_smoking IS NOT NULL AND b_smoking IS NOT NULL THEN
    parts := parts || public.mm_ordinal_closeness(
      array_position(smoke_levels, a_smoking),
      array_position(smoke_levels, b_smoking),
      array_length(smoke_levels, 1));
  END IF;

  IF a_education IS NOT NULL AND b_education IS NOT NULL THEN
    IF a_education = b_education THEN
      parts := parts || 1::numeric;
    ELSIF a_education = 'other' OR b_education = 'other' THEN
      parts := parts || 0::numeric;
    ELSE
      parts := parts || COALESCE(public.mm_ordinal_closeness(
        array_position(edu_levels, a_education),
        array_position(edu_levels, b_education),
        array_length(edu_levels, 1)), 0::numeric);
    END IF;
  END IF;

  IF cardinality(parts) = 0 THEN RETURN NULL; END IF;

  SELECT AVG(x) INTO v FROM unnest(parts) AS x;
  RETURN v;
END;
$$;

COMMENT ON FUNCTION public.mm_lifestyle_score(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT) IS
  'Drinking / smoking / education closeness, averaged over the fields both '
  'sides answered. NULL when none are shared, so the axis drops out of the '
  'denominator rather than scoring zero. Mirrors MatchingService.';

-- ── affinity: article 9, and only with consent on both sides ─────────
CREATE OR REPLACE FUNCTION public.mm_affinity_score(
  a_origins TEXT[], b_origins TEXT[],
  a_religion TEXT,  b_religion TEXT,
  a_ok_origins BOOLEAN, b_ok_origins BOOLEAN,
  a_ok_religion BOOLEAN, b_ok_religion BOOLEAN
)
RETURNS NUMERIC
LANGUAGE plpgsql
IMMUTABLE
SET search_path = public
AS $$
DECLARE
  parts NUMERIC[] := '{}';
  v NUMERIC;
BEGIN
  -- Both sides, every time. A single yes is not a mandate over the other
  -- person's data.
  IF COALESCE(a_ok_origins, false) AND COALESCE(b_ok_origins, false)
     AND COALESCE(cardinality(a_origins), 0) > 0
     AND COALESCE(cardinality(b_origins), 0) > 0 THEN
    parts := parts || public.mm_jaccard(a_origins, b_origins);
  END IF;

  IF COALESCE(a_ok_religion, false) AND COALESCE(b_ok_religion, false)
     AND a_religion IS NOT NULL AND b_religion IS NOT NULL THEN
    parts := parts || CASE WHEN a_religion = b_religion
                           THEN 1::numeric ELSE 0::numeric END;
  END IF;

  IF cardinality(parts) = 0 THEN RETURN NULL; END IF;

  SELECT AVG(x) INTO v FROM unnest(parts) AS x;
  RETURN v;
END;
$$;

COMMENT ON FUNCTION public.mm_affinity_score(
  TEXT[],TEXT[],TEXT,TEXT,BOOLEAN,BOOLEAN,BOOLEAN,BOOLEAN) IS
  'Origins overlap and religion equality, but only for the fields BOTH '
  'people consented to be matched on. NULL when neither applies, so '
  'declining is invisible in the score rather than costly.';

-- ── Le matcher, avec les deux nouveaux axes ──────────────────────────
--
-- Recréé plutôt que patché : la fonction porte les jointures du background
-- pour les deux côtés, et un dénominateur qui suit les axes réellement
-- applicables. Le reste est identique à 20260819210000 — mêmes barrières,
-- même réservation atomique, même relaxation de seuil.

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
        SELECT  peer_id,
                (
                  (sc_dist + sc_intent + sc_int + sc_age + sc_fresh
                   + COALESCE(8 * r_life, 0)
                   + COALESCE(6 * r_aff,  0))
                  * 100.0
                  / (86 + CASE WHEN r_life IS NULL THEN 0 ELSE 8 END
                        + CASE WHEN r_aff  IS NULL THEN 0 ELSE 6 END)
                ) * public.mm_history_penalty(v_self, peer_id) AS final_score
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
