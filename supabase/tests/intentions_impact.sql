-- =============================================================================
-- Impact reel de la porte dure sur les intentions
--
-- LECTURE SEULE. A coller apres 20260819210000_intentions_in_matcher.sql.
--
-- Le compte par intention repond a "qui declare quoi", pas a "combien de
-- rencontres disparaissent" : le champ est multi-selection, et la porte ne
-- refuse QUE serieux-seul contre leger-seul. Cinq mentions de 'serious' ne
-- font pas cinq profils exclusivement serieux.
--
-- Ceci mesure la seule chose qui compte avant d'activer une porte dure :
-- la part du pool qu'elle retire.
-- =============================================================================

WITH p AS (
  SELECT user_id, COALESCE(intentions, '{}'::text[]) AS ints
    FROM public.user_preferences
   WHERE intentions IS NOT NULL AND cardinality(intentions) > 0
),
paires AS (
  SELECT a.ints AS ia, b.ints AS ib
    FROM p a JOIN p b ON a.user_id < b.user_id
)
SELECT
  (SELECT count(*) FROM p)                                   AS profils,
  (SELECT count(*) FROM p WHERE ints = ARRAY['serious']::text[])
                                                             AS excl_serieux,
  (SELECT count(*) FROM p WHERE ints = ARRAY['casual']::text[])
                                                             AS excl_leger,
  count(*)                                                   AS paires_possibles,
  count(*) FILTER (
    WHERE NOT public.mm_intentions_compatible(ia, ib)
  )                                                          AS paires_bloquees,
  COALESCE(round(
    100.0 * count(*) FILTER (
      WHERE NOT public.mm_intentions_compatible(ia, ib)
    ) / NULLIF(count(*), 0)
  , 1), 0)                                                   AS pct_bloque
FROM paires;

-- Le nouvel axe separe-t-il vraiment les gens, ou donne-t-il la meme note a
-- tout le monde ? Une seule ligne dans ce resultat voudrait dire que les 15
-- points sont aussi morts que ceux des langues qu'ils remplacent.
WITH p AS (
  SELECT user_id, COALESCE(intentions, '{}'::text[]) AS ints
    FROM public.user_preferences
   WHERE intentions IS NOT NULL AND cardinality(intentions) > 0
),
paires AS (
  SELECT a.ints AS ia, b.ints AS ib
    FROM p a JOIN p b ON a.user_id < b.user_id
)
SELECT round(15 * public.mm_jaccard(ia, ib))::int AS points_intentions,
       count(*) AS paires
  FROM paires
 GROUP BY 1
 ORDER BY 1;

-- Qui declare quoi exactement, combinaisons comprises.
SELECT array_to_string(intentions, ' + ') AS combinaison, count(*) AS profils
  FROM public.user_preferences
 WHERE intentions IS NOT NULL AND cardinality(intentions) > 0
 GROUP BY 1
 ORDER BY 2 DESC, 1;
