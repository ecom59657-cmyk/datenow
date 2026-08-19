-- Quels deux comptes peuvent reellement se rencontrer ?
-- Rejoue les portes de mm_find_match, sauf la file et le heartbeat qui
-- n'existent que pendant le test. Lecture seule.
WITH me AS (
  SELECT p.id, p.first_name, p.gender, p.location,
         EXTRACT(YEAR FROM age(p.birth_date))::INT      AS age,
         p.is_banned, p.moderation_status,
         COALESCE(up.seeking_genders, '{}'::text[])     AS seek_g,
         COALESCE(up.seeking_age_min, 18)               AS seek_min,
         COALESCE(up.seeking_age_max, 120)              AS seek_max,
         COALESCE(up.max_distance_km, 50)               AS max_km,
         COALESCE(up.intentions, '{}'::text[])          AS ints
    FROM public.profiles p
    LEFT JOIN public.user_preferences up ON up.user_id = p.id
),
res AS (
  SELECT a.first_name || ' (' || COALESCE(a.gender,'?') || ', ' || a.age || ')' AS compte_a,
         b.first_name || ' (' || COALESCE(b.gender,'?') || ', ' || b.age || ')' AS compte_b,
         CASE WHEN a.is_banned OR b.is_banned
                OR a.moderation_status <> 'active'
                OR b.moderation_status <> 'active' THEN 'compte inactif'
              WHEN a.location IS NULL OR b.location IS NULL THEN 'position absente'
              WHEN NOT (cardinality(a.seek_g) = 0 OR b.gender = ANY(a.seek_g))
                OR NOT (cardinality(b.seek_g) = 0 OR a.gender = ANY(b.seek_g))
                   THEN 'genre'
              WHEN b.age NOT BETWEEN a.seek_min AND a.seek_max
                OR a.age NOT BETWEEN b.seek_min AND b.seek_max
                   THEN 'age'
              WHEN ST_Distance(a.location::geography, b.location::geography)
                   > LEAST(a.max_km, b.max_km) * 1000
                   THEN 'distance ('
                        || round(ST_Distance(a.location::geography,
                                             b.location::geography)/1000)::text
                        || ' km > ' || LEAST(a.max_km, b.max_km)::text || ' km)'
              WHEN NOT public.mm_intentions_compatible(a.ints, b.ints)
                   THEN 'intentions'
              WHEN EXISTS (SELECT 1 FROM public.blocked_users x
                            WHERE (x.user_id = a.id AND x.blocked_user_id = b.id)
                               OR (x.user_id = b.id AND x.blocked_user_id = a.id))
                   THEN 'blocage'
              ELSE 'OK -- utilisable pour le test'
         END AS verdict,
         round(ST_Distance(a.location::geography, b.location::geography)/1000)::int AS km
    FROM me a JOIN me b ON a.id < b.id
)
SELECT * FROM res
 ORDER BY (verdict LIKE 'OK%') DESC, verdict, compte_a;
