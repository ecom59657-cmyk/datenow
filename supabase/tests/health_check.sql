-- =============================================================================
-- DateNow — controle de sante de la base
--
-- LECTURE SEULE sur tes donnees : ne SELECT que le catalogue et appelle des
-- fonctions pures. La seule ecriture est une table TEMPORAIRE, propre a ta
-- session, qui disparait quand tu fermes l'onglet. Sans danger en production.
--
-- A quoi ca sert : les migrations sont appliquees a la main, donc le depot et
-- la base peuvent diverger sans que rien ne le signale. Une migration a
-- moitie collee ne leve aucune erreur — elle laisse une porte sans son
-- scoring, ou une table sans sa politique.
--
-- Les controles de comportement passent par EXECUTE plutot que par un appel
-- direct : Postgres resout les noms de fonctions a l'analyse, donc une seule
-- reference a une fonction absente ferait echouer les vingt-cinq autres
-- controles avant meme d'en executer un.
--
-- Attendu : toutes les lignes en PASS.
-- =============================================================================

DROP TABLE IF EXISTS pg_temp.hc;
CREATE TEMP TABLE hc (controle TEXT, resultat TEXT);

DO $hc$
DECLARE
  v_mm    TEXT := COALESCE((
            SELECT pg_get_functiondef(p.oid)
              FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname = 'public' AND p.proname = 'mm_find_match'
             LIMIT 1), '');
  v_fn    BOOLEAN := to_regprocedure(
            'public.mm_intentions_compatible(text[],text[])') IS NOT NULL;
  v_ck    BOOLEAN := to_regclass('public.user_background') IS NOT NULL;
  b1 BOOLEAN; b2 BOOLEAN; b3 BOOLEAN; n INT;

  FUNCTION_ABSENTE CONSTANT TEXT := 'FAIL — fonction absente (migration 20260819210000)';
BEGIN
  -- ---- A. Tables et colonnes attendues -------------------------------------
  INSERT INTO hc VALUES
    ('A1. table user_background',
     CASE WHEN v_ck THEN 'PASS'
          ELSE 'FAIL — migration 20260819200000 non appliquee' END),
    ('A2. table user_prompts',
     CASE WHEN to_regclass('public.user_prompts') IS NOT NULL THEN 'PASS'
          ELSE 'FAIL — migration 20260819180000 non appliquee' END),
    ('A3. table weekly_suggestions',
     CASE WHEN to_regclass('public.weekly_suggestions') IS NOT NULL THEN 'PASS'
          ELSE 'FAIL — migration 20260819170000 non appliquee' END),
    ('A4. colonne user_preferences.intentions',
     CASE WHEN EXISTS (SELECT 1 FROM information_schema.columns
       WHERE table_schema='public' AND table_name='user_preferences'
         AND column_name='intentions') THEN 'PASS' ELSE 'FAIL' END),
    ('A5. colonne profiles.location (geo)',
     CASE WHEN EXISTS (SELECT 1 FROM information_schema.columns
       WHERE table_schema='public' AND table_name='profiles'
         AND column_name='location') THEN 'PASS' ELSE 'FAIL' END);

  -- ---- B. user_background : securite ---------------------------------------
  INSERT INTO hc VALUES
    ('B1. RLS active sur user_background',
     CASE WHEN COALESCE((SELECT relrowsecurity FROM pg_class
       WHERE oid = to_regclass('public.user_background')), false) THEN 'PASS'
          ELSE 'FAIL — donnees sensibles sans RLS' END),
    ('B2. politique d''ecriture (proprietaire seul)',
     CASE WHEN EXISTS (SELECT 1 FROM pg_policies WHERE tablename='user_background'
       AND policyname='user_background_modify_own') THEN 'PASS' ELSE 'FAIL' END),
    ('B3. politique de lecture (hors blocage)',
     CASE WHEN EXISTS (SELECT 1 FROM pg_policies WHERE tablename='user_background'
       AND policyname='user_background_select_not_blocked')
          THEN 'PASS' ELSE 'FAIL' END),
    ('B4. le blocage est bilateral',
     CASE WHEN COALESCE((SELECT qual::text FROM pg_policies
       WHERE tablename='user_background'
         AND policyname='user_background_select_not_blocked'), '') LIKE '% OR %'
          THEN 'PASS' ELSE 'FAIL — blocage a sens unique' END),
    ('B5. suppression du profil en cascade',
     CASE WHEN EXISTS (SELECT 1 FROM pg_constraint
       WHERE conrelid = to_regclass('public.user_background')
         AND pg_get_constraintdef(oid) LIKE '%ON DELETE CASCADE%')
          THEN 'PASS' ELSE 'FAIL' END),
    ('B6. trigger updated_at',
     CASE WHEN EXISTS (SELECT 1 FROM pg_trigger
       WHERE tgrelid = to_regclass('public.user_background') AND NOT tgisinternal)
          THEN 'PASS' ELSE 'FAIL' END);

  -- ---- C. Valeurs acceptees == enums Dart ----------------------------------
  INSERT INTO hc VALUES
    ('C1. origines : les 12 valeurs Dart',
     CASE WHEN COALESCE((SELECT pg_get_constraintdef(oid) FROM pg_constraint
       WHERE conrelid = to_regclass('public.user_background')
         AND pg_get_constraintdef(oid) LIKE '%origins%' LIMIT 1), '')
       LIKE ALL (ARRAY['%africa%','%northAfrica%','%eastAsia%','%southAsia%',
         '%southeastAsia%','%caribbean%','%europe%','%latinAmerica%',
         '%middleEast%','%nativeAmerican%','%pacific%','%other%'])
       THEN 'PASS' ELSE 'FAIL' END),
    ('C2. religion : les 11 valeurs Dart',
     CASE WHEN COALESCE((SELECT pg_get_constraintdef(oid) FROM pg_constraint
       WHERE conrelid = to_regclass('public.user_background')
         AND pg_get_constraintdef(oid) LIKE '%religion%' LIMIT 1), '')
       LIKE ALL (ARRAY['%agnostic%','%atheist%','%buddhist%','%catholic%',
         '%christian%','%hindu%','%jewish%','%muslim%','%sikh%','%spiritual%',
         '%other%']) THEN 'PASS' ELSE 'FAIL' END),
    ('C3. alcool, tabac, etudes',
     CASE WHEN COALESCE((SELECT pg_get_constraintdef(oid) FROM pg_constraint
            WHERE conrelid = to_regclass('public.user_background')
              AND pg_get_constraintdef(oid) LIKE '%drinking%' LIMIT 1), '')
            LIKE ALL (ARRAY['%never%','%socially%','%often%'])
       AND COALESCE((SELECT pg_get_constraintdef(oid) FROM pg_constraint
            WHERE conrelid = to_regclass('public.user_background')
              AND pg_get_constraintdef(oid) LIKE '%smoking%' LIMIT 1), '')
            LIKE ALL (ARRAY['%never%','%occasionally%','%regularly%'])
       AND COALESCE((SELECT pg_get_constraintdef(oid) FROM pg_constraint
            WHERE conrelid = to_regclass('public.user_background')
              AND pg_get_constraintdef(oid) LIKE '%education%' LIMIT 1), '')
            LIKE ALL (ARRAY['%highSchool%','%vocational%','%bachelor%',
              '%master%','%doctorate%','%other%'])
       THEN 'PASS' ELSE 'FAIL' END);

  -- ---- D. Porte des intentions : comportement reel -------------------------
  INSERT INTO hc VALUES ('D1. fonction mm_intentions_compatible',
    CASE WHEN v_fn THEN 'PASS'
         ELSE 'FAIL — migration 20260819210000 non appliquee' END);

  IF v_fn THEN
    EXECUTE $q$ SELECT public.mm_intentions_compatible(ARRAY['serious'],ARRAY['casual'])
              = FALSE
            AND public.mm_intentions_compatible(ARRAY['casual'],ARRAY['serious'])
              = FALSE $q$ INTO b1;
    EXECUTE $q$ SELECT count(*)::int
                  FROM unnest(ARRAY['serious','feeling','talk','casual']) i,
                       unnest(ARRAY['serious','feeling','talk','casual']) j
                 WHERE NOT public.mm_intentions_compatible(ARRAY[i],ARRAY[j]) $q$
      INTO n;
    EXECUTE $q$ SELECT public.mm_intentions_compatible(NULL,ARRAY['casual'])
                   AND public.mm_intentions_compatible(ARRAY['serious'],NULL)
                   AND public.mm_intentions_compatible(ARRAY[]::text[],ARRAY['casual'])
              $q$ INTO b2;
    EXECUTE $q$ SELECT bool_and(
                    public.mm_intentions_compatible(ARRAY[i],ARRAY[j])
                  = public.mm_intentions_compatible(ARRAY[j],ARRAY[i]))
                  FROM unnest(ARRAY['serious','feeling','talk','casual']) i,
                       unnest(ARRAY['serious','feeling','talk','casual']) j $q$
      INTO b3;
    INSERT INTO hc VALUES
      ('D2. serieux seul vs leger seul refuse',
       CASE WHEN b1 THEN 'PASS' ELSE 'FAIL' END),
      ('D3. exactement 2 des 16 paires refusees',
       CASE WHEN n = 2 THEN 'PASS'
            ELSE 'FAIL — ' || n || ' paires refusees au lieu de 2' END),
      ('D4. ne renvoie jamais NULL',
       CASE WHEN b2 THEN 'PASS'
            ELSE 'FAIL — un NULL fait disparaitre la ligne du WHERE' END),
      ('D5. la regle est symetrique',
       CASE WHEN b3 THEN 'PASS' ELSE 'FAIL' END);
  ELSE
    INSERT INTO hc VALUES
      ('D2. serieux seul vs leger seul refuse', FUNCTION_ABSENTE),
      ('D3. exactement 2 des 16 paires refusees', FUNCTION_ABSENTE),
      ('D4. ne renvoie jamais NULL', FUNCTION_ABSENTE),
      ('D5. la regle est symetrique', FUNCTION_ABSENTE);
  END IF;

  -- ---- E. Moteur V2 ---------------------------------------------------------
  INSERT INTO hc VALUES
    ('E1. mm_find_match existe',
     CASE WHEN v_mm <> '' THEN 'PASS' ELSE 'FAIL' END),
    ('E2. la porte dure y est branchee',
     CASE WHEN v_mm LIKE '%mm_intentions_compatible%' THEN 'PASS'
          ELSE 'FAIL — migration collee a moitie' END),
    ('E3. les intentions sont notees (sc_intent)',
     CASE WHEN v_mm LIKE '%sc_intent%' THEN 'PASS' ELSE 'FAIL' END),
    ('E4. l''axe langues mort a disparu',
     CASE WHEN v_mm <> '' AND v_mm NOT LIKE '%sc_lang%'
                        AND v_mm NOT LIKE '%languages%'
          THEN 'PASS' ELSE 'FAIL — 15 points que personne n''obtient' END),
    ('E5. les 5 axes sont sommes',
     CASE WHEN v_mm LIKE '%sc_dist + sc_intent + sc_int + sc_age + sc_fresh%'
          THEN 'PASS' ELSE 'FAIL' END),
    ('E6. poids 40+15+20+10+15 = 100',
     CASE WHEN v_mm LIKE '%40 * (1 - LEAST%'
           AND v_mm LIKE '%15 * public.mm_jaccard(c.self_intentions%'
           AND v_mm LIKE '%20 * public.mm_jaccard(c.self_interests%'
           AND v_mm LIKE '%10 * (1 - LEAST(1.0, ABS%'
           AND v_mm LIKE '%15 * GREATEST(0, 1 - c.waited_s%'
          THEN 'PASS' ELSE 'FAIL' END);
END $hc$;

SELECT controle, resultat FROM hc ORDER BY controle;
