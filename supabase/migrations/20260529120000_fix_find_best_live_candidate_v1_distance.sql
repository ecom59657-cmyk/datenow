-- =============================================================================
-- DateNow — fix `find_best_live_candidate_v1` distance call
--
-- The original migration `20260526170000_find_best_live_candidate_v1.sql`
-- compiles and applies fine (CREATE FUNCTION succeeds because PostgreSQL
-- does not resolve inner overloads until call-time), but every actual
-- RPC invocation throws:
--
--     PostgrestException(
--       message: function st_distancesphere(geography, geography)
--                does not exist,
--       code: 42883,
--       hint: You might need to add explicit type casts.
--     )
--
-- Root cause: `profiles.location` is `GEOGRAPHY(Point, 4326)` (cf.
-- 20260526160000_geolocation_foundation.sql:19) but PostGIS only ships
-- `ST_DistanceSphere(geometry, geometry)` — there is no
-- `(geography, geography)` overload. For the `geography` type the
-- idiomatic call is `ST_Distance(geography, geography)` which already
-- returns meters on the WGS84 spheroid (more accurate than the sphere
-- approximation, microseconds slower, irrelevant for our 100 m bucket).
--
-- Surface impact: every "Trouver un date" tap reached the matching
-- screen, joined the queue (S1 OK), but the scoring RPC errored on
-- every poll → 'queue=1 eligible=0' loop with WARN stack traces and a
-- match was impossible even between two paired phones with valid
-- geography rows in `profiles.location`.
--
-- This migration replaces the function body in-place via
-- `CREATE OR REPLACE FUNCTION` so we don't change the public API —
-- arguments, return columns, RLS, GRANTs are all preserved.
--
-- See also: the original migration file was edited to keep disk and
-- DB in sync after this fix is applied.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.find_best_live_candidate_v1(
  p_self_id        UUID,
  p_min_score      SMALLINT DEFAULT 50
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

  RETURN QUERY
  WITH eligible AS (
    SELECT
      p.id AS cid,
      mq.heartbeat_at,
      -- FIX: was ST_DistanceSphere(p.location, v_self.location) —
      -- no such overload for geography. ST_Distance on geography
      -- returns meters on the WGS84 spheroid.
      ST_Distance(p.location, v_self.location)::INTEGER AS dist_m,
      DATE_PART('year', AGE(p.birth_date))::INTEGER AS c_age,
      up.interests       AS c_interests,
      up.seeking_age_min AS c_age_min,
      up.seeking_age_max AS c_age_max
    FROM matchmaking_queue mq
    JOIN profiles p ON p.id = mq.user_id
    JOIN user_preferences up ON up.user_id = p.id
    WHERE
      p.id <> v_self.id
      AND mq.heartbeat_at > now() - interval '60 seconds'
      AND p.location IS NOT NULL
      AND NOT EXISTS (
        SELECT 1 FROM blocked_users b
         WHERE (b.user_id = v_self.id AND b.blocked_user_id = p.id)
            OR (b.user_id = p.id AND b.blocked_user_id = v_self.id)
      )
      AND EXISTS (
        SELECT 1 FROM user_photos uph WHERE uph.user_id = p.id
      )
      AND NOT EXISTS (
        SELECT 1 FROM calls c
         WHERE (c.caller_id = p.id OR c.callee_id = p.id)
           AND c.status = 'live'
      )
      AND p.gender = ANY(v_self.seeking_genders)
      AND v_self.gender = ANY(up.seeking_genders)
      AND DATE_PART('year', AGE(p.birth_date))::INTEGER
          BETWEEN v_self.seeking_age_min AND v_self.seeking_age_max
      AND v_self.age
          BETWEEN up.seeking_age_min AND up.seeking_age_max
      -- FIX (same as above) — geography overload.
      AND ST_Distance(p.location, v_self.location)
          <= LEAST(v_self.max_distance_km, up.max_distance_km) * 1000
  ),
  scored AS (
    SELECT
      cid,
      dist_m,
      heartbeat_at,
      CASE
        WHEN dist_m <= 1000  THEN 30
        WHEN dist_m <= 3000  THEN 27
        WHEN dist_m <= 5000  THEN 22
        WHEN dist_m <= 10000 THEN 16
        WHEN dist_m <= 20000 THEN 10
        ELSE 0
      END AS s_dist,
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
      GREATEST(
        0,
        20 - (
          ABS(v_self.age - ((c_age_min + c_age_max)::float / 2.0))
            / GREATEST(1.0, (c_age_max - c_age_min)::float / 2.0)
            * 20
        )::INTEGER
      ) AS s_age,
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

-- GRANTs / REVOKEs are preserved by CREATE OR REPLACE but we re-assert
-- them defensively so anyone reading this migration alone gets the full
-- picture without grepping for the original.
REVOKE ALL ON FUNCTION public.find_best_live_candidate_v1(UUID, SMALLINT)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.find_best_live_candidate_v1(UUID, SMALLINT)
  TO authenticated;
