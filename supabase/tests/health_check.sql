-- =============================================================================
-- DateNow — controle de sante de la base
--
-- LECTURE SEULE, au sens strict : une seule requete SELECT sur le catalogue.
-- Ne cree rien, ne supprime rien, n'ecrit nulle part. L'editeur Supabase ne
-- doit lever aucune alerte.
--
-- A quoi ca sert : les migrations sont appliquees a la main, donc le depot et
-- la base peuvent diverger sans que rien ne le signale. Une migration a
-- moitie collee ne leve aucune erreur — elle laisse une porte sans son
-- scoring, ou une table sans sa politique.
--
-- Ce script constate ce qui EXISTE. Pour verifier que la porte des intentions
-- se COMPORTE bien, enchainer avec intentions_verify.sql une fois que le
-- controle D1 est au vert : ces appels-la ne peuvent pas cohabiter ici, car
-- Postgres resout les noms de fonctions a l'analyse et une fonction absente
-- ferait echouer les vingt-cinq controles avant d'en executer un.
--
-- Attendu : toutes les lignes en PASS.
-- =============================================================================

WITH mm AS (
  SELECT COALESCE((
    SELECT pg_get_functiondef(p.oid)
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = 'mm_find_match'
     LIMIT 1), '') AS def
),
cons AS (
  SELECT pg_get_constraintdef(oid) AS def
    FROM pg_constraint
   WHERE conrelid = to_regclass('public.user_background')
)
SELECT 'A1. table user_background' AS controle,
  CASE WHEN to_regclass('public.user_background') IS NOT NULL THEN 'PASS' ELSE 'FAIL — migration 20260819200000 non appliquee' END AS resultat
UNION ALL SELECT 'A2. table user_prompts' AS controle,
  CASE WHEN to_regclass('public.user_prompts') IS NOT NULL THEN 'PASS' ELSE 'FAIL — migration 20260819180000 non appliquee' END AS resultat
UNION ALL SELECT 'A3. table weekly_suggestions' AS controle,
  CASE WHEN to_regclass('public.weekly_suggestions') IS NOT NULL THEN 'PASS' ELSE 'FAIL — migration 20260819170000 non appliquee' END AS resultat
UNION ALL SELECT 'A4. colonne user_preferences.intentions' AS controle,
  CASE WHEN EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public'
    AND table_name='user_preferences' AND column_name='intentions') THEN 'PASS' ELSE 'FAIL' END AS resultat
UNION ALL SELECT 'A5. colonne profiles.location (geo)' AS controle,
  CASE WHEN EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public'
    AND table_name='profiles' AND column_name='location') THEN 'PASS' ELSE 'FAIL' END AS resultat
UNION ALL SELECT 'B1. RLS active sur user_background' AS controle,
  CASE WHEN COALESCE((SELECT relrowsecurity FROM pg_class
    WHERE oid = to_regclass('public.user_background')), false) THEN 'PASS' ELSE 'FAIL — donnees sensibles sans RLS' END AS resultat
UNION ALL SELECT 'B2. politique d''ecriture (proprietaire seul)' AS controle,
  CASE WHEN EXISTS (SELECT 1 FROM pg_policies WHERE tablename='user_background'
    AND policyname='user_background_modify_own') THEN 'PASS' ELSE 'FAIL' END AS resultat
UNION ALL SELECT 'B3. politique de lecture (hors blocage)' AS controle,
  CASE WHEN EXISTS (SELECT 1 FROM pg_policies WHERE tablename='user_background'
    AND policyname='user_background_select_not_blocked') THEN 'PASS' ELSE 'FAIL' END AS resultat
UNION ALL SELECT 'B4. le blocage est bilateral' AS controle,
  CASE WHEN COALESCE((SELECT qual::text FROM pg_policies WHERE tablename='user_background'
    AND policyname='user_background_select_not_blocked'), '') LIKE '% OR %' THEN 'PASS' ELSE 'FAIL — blocage a sens unique' END AS resultat
UNION ALL SELECT 'B5. suppression du profil en cascade' AS controle,
  CASE WHEN EXISTS (SELECT 1 FROM cons WHERE def LIKE '%ON DELETE CASCADE%') THEN 'PASS' ELSE 'FAIL' END AS resultat
UNION ALL SELECT 'B6. trigger updated_at' AS controle,
  CASE WHEN EXISTS (SELECT 1 FROM pg_trigger
    WHERE tgrelid = to_regclass('public.user_background') AND NOT tgisinternal) THEN 'PASS' ELSE 'FAIL' END AS resultat
UNION ALL SELECT 'C1. origines : les 12 valeurs Dart' AS controle,
  CASE WHEN COALESCE((SELECT def FROM cons WHERE def LIKE '%origins%' LIMIT 1), '')
    LIKE ALL (ARRAY['%africa%','%northAfrica%','%eastAsia%','%southAsia%',
      '%southeastAsia%','%caribbean%','%europe%','%latinAmerica%',
      '%middleEast%','%nativeAmerican%','%pacific%','%other%']) THEN 'PASS' ELSE 'FAIL' END AS resultat
UNION ALL SELECT 'C2. religion : les 11 valeurs Dart' AS controle,
  CASE WHEN COALESCE((SELECT def FROM cons WHERE def LIKE '%religion%' LIMIT 1), '')
    LIKE ALL (ARRAY['%agnostic%','%atheist%','%buddhist%','%catholic%',
      '%christian%','%hindu%','%jewish%','%muslim%','%sikh%','%spiritual%','%other%']) THEN 'PASS' ELSE 'FAIL' END AS resultat
UNION ALL SELECT 'C3. alcool, tabac, etudes' AS controle,
  CASE WHEN COALESCE((SELECT def FROM cons WHERE def LIKE '%drinking%' LIMIT 1), '')
      LIKE ALL (ARRAY['%never%','%socially%','%often%'])
   AND COALESCE((SELECT def FROM cons WHERE def LIKE '%smoking%' LIMIT 1), '')
      LIKE ALL (ARRAY['%never%','%occasionally%','%regularly%'])
   AND COALESCE((SELECT def FROM cons WHERE def LIKE '%education%' LIMIT 1), '')
      LIKE ALL (ARRAY['%highSchool%','%vocational%','%bachelor%','%master%',
        '%doctorate%','%other%']) THEN 'PASS' ELSE 'FAIL' END AS resultat
UNION ALL SELECT 'D1. fonction mm_intentions_compatible' AS controle,
  CASE WHEN to_regprocedure('public.mm_intentions_compatible(text[],text[])') IS NOT NULL THEN 'PASS' ELSE 'FAIL — migration 20260819210000 non appliquee' END AS resultat
UNION ALL SELECT 'D2. elle est IMMUTABLE (indexable, cachable)' AS controle,
  CASE WHEN COALESCE((SELECT p.provolatile = 'i' FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname='public' AND p.proname='mm_intentions_compatible'
   LIMIT 1), false) THEN 'PASS' ELSE 'FAIL' END AS resultat
UNION ALL SELECT 'E1. mm_find_match existe' AS controle,
  CASE WHEN (SELECT def FROM mm) <> '' THEN 'PASS' ELSE 'FAIL' END AS resultat
UNION ALL SELECT 'E2. la porte dure y est branchee' AS controle,
  CASE WHEN (SELECT def FROM mm) LIKE '%mm_intentions_compatible%' THEN 'PASS' ELSE 'FAIL — migration collee a moitie' END AS resultat
UNION ALL SELECT 'E3. les intentions sont notees (sc_intent)' AS controle,
  CASE WHEN (SELECT def FROM mm) LIKE '%sc_intent%' THEN 'PASS' ELSE 'FAIL' END AS resultat
UNION ALL SELECT 'E4. l''axe langues mort a disparu' AS controle,
  CASE WHEN (SELECT def FROM mm) <> '' AND (SELECT def FROM mm) NOT LIKE '%sc_lang%'
   AND (SELECT def FROM mm) NOT LIKE '%languages%' THEN 'PASS' ELSE 'FAIL — 15 points que personne n''obtient' END AS resultat
UNION ALL SELECT 'E5. les 5 axes sont sommes' AS controle,
  CASE WHEN (SELECT def FROM mm) LIKE '%sc_dist + sc_intent + sc_int + sc_age + sc_fresh%' THEN 'PASS' ELSE 'FAIL' END AS resultat
UNION ALL SELECT 'E6. poids 40+15+20+10+15 = 100' AS controle,
  CASE WHEN (SELECT def FROM mm) LIKE '%40 * (1 - LEAST%'
   AND (SELECT def FROM mm) LIKE '%15 * public.mm_jaccard(c.self_intentions%'
   AND (SELECT def FROM mm) LIKE '%20 * public.mm_jaccard(c.self_interests%'
   AND (SELECT def FROM mm) LIKE '%10 * (1 - LEAST(1.0, ABS%'
   AND (SELECT def FROM mm) LIKE '%15 * GREATEST(0, 1 - c.waited_s%' THEN 'PASS' ELSE 'FAIL' END AS resultat
ORDER BY 1;
