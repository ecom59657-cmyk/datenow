-- =============================================================================
-- DateNow — Debug queries to inspect matching state
--
-- Paste any block into the Supabase SQL editor (or `supabase db query …`)
-- when two test users fail to match. Each block is self-contained.
-- =============================================================================

-- 1. Confirm both test users exist in auth.users.
--    Replace the emails before running.
SELECT id, email, email_confirmed_at, created_at
FROM auth.users
WHERE email IN ('test1@example.com', 'test2@example.com');

-- 2. Confirm a profiles row exists for each user, with the matching
--    fields filled in. NULL gender or first_name means the user never
--    completed onboarding — that profile is filtered out of the discovery
--    pool by the new RLS policy `profiles_select_for_discovery`.
SELECT id,
       first_name,
       birth_date,
       gender,
       sexual_orientation,
       (CURRENT_DATE - birth_date) / 365 AS approx_age
FROM public.profiles
WHERE id IN (
  SELECT id FROM auth.users
  WHERE email IN ('test1@example.com', 'test2@example.com')
);

-- 3. Confirm user_preferences row for each user. All five list columns
--    should be non-empty arrays for a meaningful score.
SELECT user_id,
       seeking_genders,
       seeking_age_min,
       seeking_age_max,
       max_distance_km,
       intentions,
       interests,
       availability
FROM public.user_preferences
WHERE user_id IN (
  SELECT id FROM auth.users
  WHERE email IN ('test1@example.com', 'test2@example.com')
);

-- 4. Quick reciprocity check between two specific users. Plug their UUIDs
--    in; the query returns one row per direction so you can see exactly
--    which side rejects the other.
--    Replace the placeholders.
WITH a AS (
  SELECT p.id, p.gender, EXTRACT(YEAR FROM AGE(p.birth_date))::int AS age,
         up.seeking_genders, up.seeking_age_min, up.seeking_age_max,
         up.max_distance_km
  FROM public.profiles p
  JOIN public.user_preferences up ON up.user_id = p.id
  WHERE p.id = '<USER_A_UUID>'
),
b AS (
  SELECT p.id, p.gender, EXTRACT(YEAR FROM AGE(p.birth_date))::int AS age,
         up.seeking_genders, up.seeking_age_min, up.seeking_age_max,
         up.max_distance_km
  FROM public.profiles p
  JOIN public.user_preferences up ON up.user_id = p.id
  WHERE p.id = '<USER_B_UUID>'
)
SELECT 'A→B'                                                AS dir,
       (b.gender = ANY(a.seeking_genders))                  AS gender_ok,
       (b.age BETWEEN a.seeking_age_min AND a.seeking_age_max) AS age_ok
FROM a, b
UNION ALL
SELECT 'B→A',
       (a.gender = ANY(b.seeking_genders)),
       (a.age BETWEEN b.seeking_age_min AND b.seeking_age_max)
FROM a, b;

-- 5. Confirm the new RLS policies are in place. After applying
--    20260514120000_matching_discovery_rls.sql you should see
--    `profiles_select_for_discovery` and `user_prefs_select_for_discovery`.
SELECT schemaname, tablename, policyname
FROM pg_policies
WHERE schemaname = 'public'
  AND tablename IN ('profiles', 'user_preferences')
ORDER BY tablename, policyname;

-- 6. Inspect persisted weekly_suggestions / matches state (the client
--    holds these in memory in the current build, so these rows are
--    expected to be empty until server-side persistence ships).
SELECT * FROM public.weekly_suggestions
WHERE user_id IN (
  SELECT id FROM auth.users
  WHERE email IN ('test1@example.com', 'test2@example.com')
)
ORDER BY created_at DESC LIMIT 20;

SELECT * FROM public.matches
WHERE user_a_id IN (
  SELECT id FROM auth.users
  WHERE email IN ('test1@example.com', 'test2@example.com')
) OR user_b_id IN (
  SELECT id FROM auth.users
  WHERE email IN ('test1@example.com', 'test2@example.com')
)
ORDER BY created_at DESC LIMIT 20;

-- 7. Block/report state — if user A blocked user B (or vice versa) the
--    matcher should never propose them; this query surfaces that.
SELECT user_id, blocked_user_id
FROM public.blocked_users
WHERE user_id IN (
  SELECT id FROM auth.users
  WHERE email IN ('test1@example.com', 'test2@example.com')
)
   OR blocked_user_id IN (
  SELECT id FROM auth.users
  WHERE email IN ('test1@example.com', 'test2@example.com')
);

SELECT reporter_id, reported_user_id, created_at
FROM public.reports
WHERE reporter_id IN (
  SELECT id FROM auth.users
  WHERE email IN ('test1@example.com', 'test2@example.com')
);
