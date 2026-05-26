-- =============================================================================
-- DateNow — find_best_live_candidate_v1 (express sub-phase before 1.5)
--
-- Tonight-test RPC. Replaces the client-side
--     calculateCompatibility(self, peer, distanceKm: 10)
-- loop with a real server-side query that:
--   1) uses the PostGIS `location` columns (phase 1.1) for actual
--      distance — no more hardcoded 10 km,
--   2) applies the essential hard gates (self, blocked, busy, photo,
--      gender/age symmetric, online + fresh heartbeat, real distance ≤
--      min(self.max, peer.max)),
--   3) scores survivors on 100 pts (distance 30 + interests 30 + age
--      20 + freshness 20),
--   4) returns the BEST candidate above the threshold (not the first
--      one to pass), with a full breakdown + a structured
--      rejection_reason when nothing matches.
--
-- This is NOT the full v3 algorithm. Reserved for v3 (sub-phase 1.5):
--   - intentions scoring, profile quality, rotation, anti-starvation,
--   - freshness decay (expansion radius + adaptive threshold),
--   - compatibility_reasons[],
--   - conv_quality / abandonment scores (Phase 2),
--   - banned check (column doesn't exist yet — added in 1.4).
--
-- The function is SECURITY DEFINER so it bypasses RLS to inspect peer
-- profiles + preferences + photos. It still ALWAYS checks the caller
-- via the `p_self_id` arg — there is no "look at anybody" mode.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.find_best_live_candidate_v1(
  p_self_id        UUID,
  p_min_score      SMALLINT DEFAULT 50  -- temp threshold for tonight
)
RETURNS TABLE (
  candidate_id          UUID,
  total_score           SMALLINT,
  score_distance        SMALLINT,
  score_interests       SMALLINT,
  score_age             SMALLINT,
  score_freshness       SMALLINT,
  distance_m            INTEGER,
  rejection_reason      TEXT,
  candidates_evaluated  INTEGER,
  queue_size            INTEGER
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_self           RECORD;
  v_queue_size     INTEGER;
BEGIN
  -- ── Load self core (profile + prefs + photo flag + busy flag) ────────
  SELECT
    p.id,
    p.gender,
    p.location,
    DATE_PART('year', AGE(p.birth_date))::INTEGER AS age,
    up.seeking_genders,
    up.seeking_age_min,
    up.seeking_age_max,
    up.max_distance_km,
    up.interests,
    EXISTS(SELECT 1 FROM user_photos uph WHERE uph.user_id = p.id) AS has_photo,
    EXISTS(SELECT 1 FROM calls c
            WHERE (c.caller_id = p.id OR c.callee_id = p.id)
              AND c.status = 'live') AS busy
  INTO v_self
  FROM profiles p
  JOIN user_preferences up ON up.user_id = p.id
  WHERE p.id = p_self_id;

  v_queue_size := (
    SELECT count(*)::INTEGER
      FROM matchmaking_queue
     WHERE heartbeat_at > now() - interval '60 seconds'
  );

  -- ── Self preconditions ───────────────────────────────────────────────
  IF NOT FOUND THEN
    RETURN QUERY SELECT
      NULL::UUID, NULL::SMALLINT, NULL::SMALLINT, NULL::SMALLINT,
      NULL::SMALLINT, NULL::SMALLINT, NULL::INTEGER,
      'self_not_found'::TEXT, 0::INTEGER, v_queue_size;
    RETURN;
  END IF;

  IF v_self.location IS NULL THEN
    RETURN QUERY SELECT
      NULL::UUID, NULL::SMALLINT, NULL::SMALLINT, NULL::SMALLINT,
      NULL::SMALLINT, NULL::SMALLINT, NULL::INTEGER,
      'no_location_self'::TEXT, 0::INTEGER, v_queue_size;
    RETURN;
  END IF;

  IF NOT v_self.has_photo THEN
    RETURN QUERY SELECT
      NULL::UUID, NULL::SMALLINT, NULL::SMALLINT, NULL::SMALLINT,
      NULL::SMALLINT, NULL::SMALLINT, NULL::INTEGER,
      'no_photo_self'::TEXT, 0::INTEGER, v_queue_size;
    RETURN;
  END IF;

  IF v_self.busy THEN
    RETURN QUERY SELECT
      NULL::UUID, NULL::SMALLINT, NULL::SMALLINT, NULL::SMALLINT,
      NULL::SMALLINT, NULL::SMALLINT, NULL::INTEGER,
      'self_already_in_call'::TEXT, 0::INTEGER, v_queue_size;
    RETURN;
  END IF;

  -- ── Eligible candidates + score in one query, then either emit the
  --    best one or emit a structured rejection (UNION ALL mutually
  --    exclusive via WHERE NOT EXISTS) ──────────────────────────────────
  RETURN QUERY
  WITH eligible AS (
    SELECT
      p.id AS cid,
      mq.heartbeat_at,
      ST_DistanceSphere(p.location, v_self.location)::INTEGER AS dist_m,
      DATE_PART('year', AGE(p.birth_date))::INTEGER AS c_age,
      up.interests       AS c_interests,
      up.seeking_age_min AS c_age_min,
      up.seeking_age_max AS c_age_max
    FROM matchmaking_queue mq
    JOIN profiles p ON p.id = mq.user_id
    JOIN user_preferences up ON up.user_id = p.id
    WHERE
      -- Self exclusion
      p.id <> v_self.id
      -- Online + fresh heartbeat (60s window matches presence-stale cutoff)
      AND mq.heartbeat_at > now() - interval '60 seconds'
      -- Peer must have a location
      AND p.location IS NOT NULL
      -- Bidirectional block check
      AND NOT EXISTS (
        SELECT 1 FROM blocked_users b
         WHERE (b.user_id = v_self.id AND b.blocked_user_id = p.id)
            OR (b.user_id = p.id AND b.blocked_user_id = v_self.id)
      )
      -- Peer has a photo (mirror the photo guard)
      AND EXISTS (
        SELECT 1 FROM user_photos uph WHERE uph.user_id = p.id
      )
      -- Peer not in a live call
      AND NOT EXISTS (
        SELECT 1 FROM calls c
         WHERE (c.caller_id = p.id OR c.callee_id = p.id)
           AND c.status = 'live'
      )
      -- Reciprocal gender / orientation gate
      AND p.gender = ANY(v_self.seeking_genders)
      AND v_self.gender = ANY(up.seeking_genders)
      -- Reciprocal age gate
      AND DATE_PART('year', AGE(p.birth_date))::INTEGER
          BETWEEN v_self.seeking_age_min AND v_self.seeking_age_max
      AND v_self.age
          BETWEEN up.seeking_age_min AND up.seeking_age_max
      -- Real distance ≤ tighter of the two max_distance_km preferences
      AND ST_DistanceSphere(p.location, v_self.location)
          <= LEAST(v_self.max_distance_km, up.max_distance_km) * 1000
  ),
  scored AS (
    SELECT
      cid,
      dist_m,
      heartbeat_at,
      -- A. Distance — 30 pts
      CASE
        WHEN dist_m <= 1000  THEN 30
        WHEN dist_m <= 3000  THEN 27
        WHEN dist_m <= 5000  THEN 22
        WHEN dist_m <= 10000 THEN 16
        WHEN dist_m <= 20000 THEN 10
        ELSE 0
      END AS s_dist,
      -- B. Common interests — 30 pts (count overlap of array elements)
      CASE (
        SELECT count(*)::INTEGER
          FROM unnest(coalesce(c_interests, '{}'::TEXT[])) i
         WHERE i = ANY(coalesce(v_self.interests, '{}'::TEXT[]))
      )
        WHEN 0 THEN 0
        WHEN 1 THEN 12
        WHEN 2 THEN 22
        ELSE 30
      END AS s_int,
      -- D. Age centered on peer's seeking range — 20 pts
      GREATEST(
        0,
        20 - (
          ABS(v_self.age - ((c_age_min + c_age_max)::float / 2.0))
            / GREATEST(1.0, (c_age_max - c_age_min)::float / 2.0)
            * 20
        )::INTEGER
      ) AS s_age,
      -- E. Heartbeat freshness — 20 pts
      CASE
        WHEN EXTRACT(EPOCH FROM (now() - heartbeat_at)) < 10 THEN 20
        WHEN EXTRACT(EPOCH FROM (now() - heartbeat_at)) < 30 THEN 14
        WHEN EXTRACT(EPOCH FROM (now() - heartbeat_at)) < 60 THEN 6
        ELSE 0
      END AS s_fresh
    FROM eligible
  ),
  scored_with_total AS (
    SELECT *, (s_dist + s_int + s_age + s_fresh) AS total
      FROM scored
  ),
  best AS (
    SELECT * FROM scored_with_total
     WHERE total >= p_min_score
     ORDER BY total DESC, heartbeat_at DESC
     LIMIT 1
  ),
  totals AS (
    SELECT count(*)::INTEGER AS n FROM scored_with_total
  )
  -- happy path
  SELECT
    b.cid,
    b.total::SMALLINT,
    b.s_dist::SMALLINT,
    b.s_int::SMALLINT,
    b.s_age::SMALLINT,
    b.s_fresh::SMALLINT,
    b.dist_m,
    NULL::TEXT,
    t.n,
    v_queue_size
  FROM best b, totals t

  UNION ALL

  -- structured rejection (only when no `best` row exists)
  SELECT
    NULL::UUID,
    NULL::SMALLINT,
    NULL::SMALLINT,
    NULL::SMALLINT,
    NULL::SMALLINT,
    NULL::SMALLINT,
    NULL::INTEGER,
    CASE
      WHEN v_queue_size = 0 THEN 'queue_empty'
      WHEN v_queue_size = 1 THEN 'only_self_in_queue'
      WHEN t.n = 0          THEN 'all_filtered_out'
      ELSE                       'best_below_threshold_' || p_min_score::text
    END,
    t.n,
    v_queue_size
  FROM totals t
  WHERE NOT EXISTS (SELECT 1 FROM best);
END;
$$;

REVOKE ALL ON FUNCTION public.find_best_live_candidate_v1(UUID, SMALLINT)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.find_best_live_candidate_v1(UUID, SMALLINT)
  TO authenticated;

COMMENT ON FUNCTION public.find_best_live_candidate_v1(UUID, SMALLINT) IS
  'Express RPC (pre-1.5). Returns the best-scoring live candidate for '
  'p_self_id above p_min_score, with full score breakdown + real PostGIS '
  'distance, or a structured rejection_reason when no match exists. '
  'Superseded by find_best_live_candidate (full v3) in sub-phase 1.5.';
