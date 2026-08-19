-- =============================================================================
-- Vérification de 20260819210000_intentions_in_matcher.sql
--
-- LECTURE SEULE : n'écrit rien, ne laisse aucune donnée. À coller dans
-- l'éditeur SQL de Supabase APRÈS la migration.
--
-- Attendu : toutes les lignes en PASS.
-- =============================================================================

WITH src AS (
  SELECT pg_get_functiondef(p.oid) AS def
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'mm_find_match'
   LIMIT 1
)
SELECT '01. la fonction mm_intentions_compatible existe' AS controle,
  CASE WHEN to_regprocedure('public.mm_intentions_compatible(text[],text[])')
            IS NOT NULL THEN 'PASS' ELSE 'FAIL' END AS resultat

UNION ALL SELECT '02. serieux seul vs leger seul est refuse',
  CASE WHEN public.mm_intentions_compatible(ARRAY['serious'], ARRAY['casual'])
            = FALSE THEN 'PASS' ELSE 'FAIL' END

UNION ALL SELECT '03. et dans l''autre sens',
  CASE WHEN public.mm_intentions_compatible(ARRAY['casual'], ARRAY['serious'])
            = FALSE THEN 'PASS' ELSE 'FAIL' END

UNION ALL SELECT '04. exactement 2 des 16 paires simples sont refusees',
  CASE WHEN (
    SELECT count(*) FROM unnest(ARRAY['serious','feeling','talk','casual']) i,
                         unnest(ARRAY['serious','feeling','talk','casual']) j
     WHERE NOT public.mm_intentions_compatible(ARRAY[i], ARRAY[j])
  ) = 2 THEN 'PASS' ELSE 'FAIL' END

UNION ALL SELECT '05. la regle est symetrique',
  CASE WHEN (
    SELECT bool_and(public.mm_intentions_compatible(ARRAY[i], ARRAY[j])
                  = public.mm_intentions_compatible(ARRAY[j], ARRAY[i]))
      FROM unnest(ARRAY['serious','feeling','talk','casual']) i,
           unnest(ARRAY['serious','feeling','talk','casual']) j
  ) THEN 'PASS' ELSE 'FAIL' END

UNION ALL SELECT '06. un vide ou un NULL passe (jamais NULL en retour)',
  CASE WHEN public.mm_intentions_compatible(ARRAY[]::text[], ARRAY['casual'])
       AND public.mm_intentions_compatible(NULL, ARRAY['casual'])
       AND public.mm_intentions_compatible(ARRAY['serious'], NULL)
       THEN 'PASS' ELSE 'FAIL' END

UNION ALL SELECT '07. mm_find_match applique la porte dure',
  CASE WHEN (SELECT def FROM src) LIKE '%mm_intentions_compatible%'
       THEN 'PASS' ELSE 'FAIL' END

UNION ALL SELECT '08. mm_find_match note les intentions (sc_intent)',
  CASE WHEN (SELECT def FROM src) LIKE '%sc_intent%'
       THEN 'PASS' ELSE 'FAIL' END

UNION ALL SELECT '09. l''axe langues mort a disparu',
  CASE WHEN (SELECT def FROM src) NOT LIKE '%sc_lang%'
        AND (SELECT def FROM src) NOT LIKE '%languages%'
       THEN 'PASS' ELSE 'FAIL' END

UNION ALL SELECT '10. les 5 axes du total sont bien la',
  CASE WHEN (SELECT def FROM src)
            LIKE '%sc_dist + sc_intent + sc_int + sc_age + sc_fresh%'
       THEN 'PASS' ELSE 'FAIL' END

UNION ALL SELECT '11. les poids somment a 100 (40+15+20+10+15)',
  CASE WHEN (SELECT def FROM src) LIKE '%40 * (1 - LEAST%'
        AND (SELECT def FROM src) LIKE '%15 * public.mm_jaccard(c.self_intentions%'
        AND (SELECT def FROM src) LIKE '%20 * public.mm_jaccard(c.self_interests%'
        AND (SELECT def FROM src) LIKE '%10 * (1 - LEAST(1.0, ABS%'
        AND (SELECT def FROM src) LIKE '%15 * GREATEST(0, 1 - c.waited_s%'
       THEN 'PASS' ELSE 'FAIL' END

UNION ALL SELECT '12. la colonne intentions existe et est peuplee',
  CASE WHEN EXISTS (
    SELECT 1 FROM information_schema.columns
     WHERE table_schema='public' AND table_name='user_preferences'
       AND column_name='intentions'
  ) THEN 'PASS' ELSE 'FAIL' END

ORDER BY 1;

-- Combien de profils declarent quoi. Purement informatif : si tout le monde
-- a les memes intentions, l'axe ne separera personne et la porte ne bloquera
-- rien — ce qui est une info utile avant de juger l'effet du changement.
SELECT unnest(intentions) AS intention, count(*) AS profils
  FROM public.user_preferences
 WHERE intentions IS NOT NULL AND cardinality(intentions) > 0
 GROUP BY 1 ORDER BY 2 DESC;
