-- =============================================================================
-- user_background — behavioural checks
--
-- Unlike flow_checks.sql, this one WRITES. It is meant for the disposable
-- Postgres that scripts/test_user_background_sql.sh spins up, never for the
-- production project.
--
-- It asserts the two things a CHECK-and-RLS table is bought for: that bad
-- values are refused, and that the read policy actually hides what it claims
-- to hide. Both are claims the Dart test suite cannot reach — a widget test
-- proves nobody can type "jedi", it does not prove the database would refuse
-- it if something else did.
--
-- Expected: every row PASS, and no row at all is the failure mode this
-- script's runner checks for too.
-- =============================================================================

CREATE TEMP TABLE results (n INT, name TEXT, status TEXT);

-- Fixtures -------------------------------------------------------------------
INSERT INTO auth.users(id) VALUES
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb');
INSERT INTO public.profiles(id) VALUES
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb');

GRANT USAGE ON SCHEMA public, auth TO authenticated;
GRANT ALL ON public.user_background, public.blocked_users TO authenticated;
GRANT EXECUTE ON FUNCTION auth.uid() TO authenticated;

-- 1 — someone who skipped the step ------------------------------------------
INSERT INTO public.user_background(user_id)
  VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
INSERT INTO results
SELECT 1, 'an empty row is accepted (the step was skipped)',
  CASE WHEN origins = '{}' AND religion IS NULL AND drinking IS NULL
            AND smoking IS NULL AND education IS NULL
       THEN 'PASS' ELSE 'FAIL' END
FROM public.user_background
WHERE user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';

-- 2 — every enum value the app can send is accepted --------------------------
DO $$
DECLARE ok BOOLEAN := TRUE;
        v TEXT;
BEGIN
  FOREACH v IN ARRAY ARRAY['africa','northAfrica','eastAsia','southAsia',
      'southeastAsia','caribbean','europe','latinAmerica','middleEast',
      'nativeAmerican','pacific','other'] LOOP
    BEGIN
      UPDATE public.user_background SET origins = ARRAY[v]
        WHERE user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
    EXCEPTION WHEN check_violation THEN ok := FALSE;
    END;
  END LOOP;
  FOREACH v IN ARRAY ARRAY['agnostic','atheist','buddhist','catholic',
      'christian','hindu','jewish','muslim','sikh','spiritual','other'] LOOP
    BEGIN
      UPDATE public.user_background SET religion = v
        WHERE user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
    EXCEPTION WHEN check_violation THEN ok := FALSE;
    END;
  END LOOP;
  FOREACH v IN ARRAY ARRAY['highSchool','vocational','bachelor','master',
      'doctorate','other'] LOOP
    BEGIN
      UPDATE public.user_background SET education = v
        WHERE user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
    EXCEPTION WHEN check_violation THEN ok := FALSE;
    END;
  END LOOP;
  INSERT INTO results VALUES
    (2, 'every Dart enum value is accepted', CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END);
END $$;

-- 3..6 — values the app can never send are refused ---------------------------
DO $$
DECLARE n INT;
        cases TEXT[][] := ARRAY[
          ARRAY['3','an unknown origin is refused',
                'UPDATE public.user_background SET origins = ARRAY[''atlantis'']'],
          ARRAY['4','an unknown religion is refused',
                'UPDATE public.user_background SET religion = ''jedi'''],
          ARRAY['5','snake_case is refused (north_africa vs northAfrica)',
                'UPDATE public.user_background SET origins = ARRAY[''north_africa'']'],
          ARRAY['6','an unknown education level is refused',
                'UPDATE public.user_background SET education = ''postdoc''']
        ];
        c TEXT[];
BEGIN
  FOREACH c SLICE 1 IN ARRAY cases LOOP
    BEGIN
      EXECUTE c[3];
      INSERT INTO results VALUES (c[1]::int, c[2], 'FAIL');
    EXCEPTION WHEN check_violation THEN
      INSERT INTO results VALUES (c[1]::int, c[2], 'PASS');
    END;
  END LOOP;
END $$;

-- 7 — one row per person -----------------------------------------------------
DO $$
BEGIN
  INSERT INTO public.user_background(user_id)
    VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
  INSERT INTO results VALUES (7, 'a second row for the same person is refused', 'FAIL');
EXCEPTION WHEN unique_violation THEN
  INSERT INTO results VALUES (7, 'a second row for the same person is refused', 'PASS');
END $$;

-- 8 — updated_at maintains itself -------------------------------------------
INSERT INTO results
SELECT 8, 'the updated_at trigger fires',
  CASE WHEN updated_at > created_at THEN 'PASS' ELSE 'FAIL' END
FROM public.user_background WHERE user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';

-- 9 — RLS is on --------------------------------------------------------------
INSERT INTO results
SELECT 9, 'row level security is enabled',
  CASE WHEN relrowsecurity THEN 'PASS' ELSE 'FAIL' END
FROM pg_class WHERE relname = 'user_background';

-- 10 — reachable by a peer ---------------------------------------------------
INSERT INTO public.user_background(user_id, religion)
  VALUES ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'jewish');
-- The count is taken while wearing the role, then recorded after taking it
-- off: `authenticated` has no rights on the results table, and an INSERT
-- from inside the role aborts the check it was meant to record.
SET ROLE authenticated;
SET request.jwt.claim.sub = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
SELECT count(*) AS c FROM public.user_background \gset peer_
RESET ROLE; RESET request.jwt.claim.sub;
INSERT INTO results VALUES (10, 'a signed-in peer can read another background',
  CASE WHEN :peer_c = 2 THEN 'PASS' ELSE 'FAIL' END);

SET ROLE authenticated;
SET request.jwt.claim.sub = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';

-- 11 — nobody writes someone else's row --------------------------------------
UPDATE public.user_background SET religion = 'atheist'
  WHERE user_id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
RESET ROLE; RESET request.jwt.claim.sub;
INSERT INTO results
SELECT 11, 'A cannot overwrite B''s answers',
  CASE WHEN religion = 'jewish' THEN 'PASS' ELSE 'FAIL' END
FROM public.user_background WHERE user_id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';

-- 12 — nobody invents a row for someone else ---------------------------------
DO $$
BEGIN
  SET LOCAL ROLE authenticated;
  SET LOCAL request.jwt.claim.sub = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  INSERT INTO public.user_background(user_id, religion)
    VALUES ('cccccccc-cccc-cccc-cccc-cccccccccccc', 'hindu');
  RESET ROLE;
  INSERT INTO results VALUES (12, 'A cannot create a row in B''s name', 'FAIL');
EXCEPTION WHEN insufficient_privilege OR foreign_key_violation THEN
  RESET ROLE;
  INSERT INTO results VALUES (12, 'A cannot create a row in B''s name', 'PASS');
END $$;

-- 13/14 — a block cuts the read, both ways -----------------------------------
INSERT INTO public.blocked_users(user_id, blocked_user_id)
  VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
          'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb');

SET ROLE authenticated;
SET request.jwt.claim.sub = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
SELECT count(*) AS c FROM public.user_background \gset blocker_
RESET ROLE; RESET request.jwt.claim.sub;
INSERT INTO results VALUES (13,
  'after blocking, the blocker sees only their own row',
  CASE WHEN :blocker_c = 1 THEN 'PASS' ELSE 'FAIL' END);

SET ROLE authenticated;
SET request.jwt.claim.sub = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
SELECT count(*) AS c FROM public.user_background \gset blocked_
RESET ROLE; RESET request.jwt.claim.sub;
INSERT INTO results VALUES (14,
  'and the blocked person loses the read too',
  CASE WHEN :blocked_c = 1 THEN 'PASS' ELSE 'FAIL' END);

-- 15 — no JWT, nothing --------------------------------------------------------
SET ROLE authenticated;
SELECT count(*) AS c FROM public.user_background \gset anon_
RESET ROLE;
INSERT INTO results VALUES (15,
  'with no auth.uid(), nothing is readable',
  CASE WHEN :anon_c = 0 THEN 'PASS' ELSE 'FAIL' END);

-- 16 — deleting the profile takes the answers with it -------------------------
DELETE FROM public.profiles WHERE id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
INSERT INTO results
SELECT 16, 'deleting the profile cascades to the background',
  CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END
FROM public.user_background WHERE user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';

SELECT lpad(n::text, 2) AS "#", status, name FROM results ORDER BY n;
