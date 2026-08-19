-- =============================================================================
-- mm_intentions_compatible — the hard gate, on its own
--
-- Run by scripts/test_mm_intentions_sql.sh against a throwaway Postgres.
-- `mm_find_match` itself cannot be exercised locally: it needs PostGIS, a
-- populated queue and two live heartbeats. Which is precisely why the rule
-- lives in a pure function — this is the part that can be wrong, and this is
-- the part that gets tested.
--
-- Every row must read PASS.
-- =============================================================================

CREATE TEMP TABLE results (n INT, name TEXT, status TEXT);

CREATE OR REPLACE FUNCTION pg_temp.chk(
  n INT, name TEXT, a TEXT[], b TEXT[], expected BOOLEAN
) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE got BOOLEAN;
BEGIN
  got := public.mm_intentions_compatible(a, b);
  INSERT INTO results VALUES (
    n, name, CASE WHEN got IS NOT DISTINCT FROM expected THEN 'PASS' ELSE 'FAIL' END
  );
END $$;

-- The one refusal ------------------------------------------------------------
SELECT pg_temp.chk(1, 'serious alone vs casual alone is refused',
  ARRAY['serious'], ARRAY['casual'], FALSE);
SELECT pg_temp.chk(2, 'and the other way round',
  ARRAY['casual'], ARRAY['serious'], FALSE);

-- Overlap always wins --------------------------------------------------------
SELECT pg_temp.chk(3, 'identical intentions pass',
  ARRAY['serious'], ARRAY['serious'], TRUE);
SELECT pg_temp.chk(4, 'any overlap passes, even alongside the clash',
  ARRAY['serious','casual'], ARRAY['casual'], TRUE);
SELECT pg_temp.chk(5, 'partial overlap passes',
  ARRAY['feeling','talk'], ARRAY['talk','casual'], TRUE);

-- Silence is not opposition --------------------------------------------------
SELECT pg_temp.chk(6, 'an empty side passes',
  ARRAY[]::TEXT[], ARRAY['casual'], TRUE);
SELECT pg_temp.chk(7, 'the other empty side passes',
  ARRAY['serious'], ARRAY[]::TEXT[], TRUE);
SELECT pg_temp.chk(8, 'both empty pass',
  ARRAY[]::TEXT[], ARRAY[]::TEXT[], TRUE);
SELECT pg_temp.chk(9, 'NULL passes rather than poisoning the WHERE',
  NULL, ARRAY['casual'], TRUE);
SELECT pg_temp.chk(10, 'NULL on the other side too',
  ARRAY['serious'], NULL, TRUE);

-- The middle of the range never blocks ---------------------------------------
SELECT pg_temp.chk(11, 'feeling vs casual passes',
  ARRAY['feeling'], ARRAY['casual'], TRUE);
SELECT pg_temp.chk(12, 'talk vs serious passes',
  ARRAY['talk'], ARRAY['serious'], TRUE);
SELECT pg_temp.chk(13, 'feeling vs talk passes',
  ARRAY['feeling'], ARRAY['talk'], TRUE);

-- "Exclusively" means exactly one -------------------------------------------
SELECT pg_temp.chk(14, 'serious+feeling vs casual passes (not exclusive)',
  ARRAY['serious','feeling'], ARRAY['casual'], TRUE);
SELECT pg_temp.chk(15, 'serious vs casual+talk passes (not exclusive)',
  ARRAY['serious'], ARRAY['casual','talk'], TRUE);

-- The gate must never return NULL: a NULL in a WHERE drops the row silently.
INSERT INTO results
SELECT 16, 'never returns NULL, whatever the input',
  CASE WHEN bool_and(public.mm_intentions_compatible(x, y) IS NOT NULL)
       THEN 'PASS' ELSE 'FAIL' END
FROM (VALUES
  (NULL::TEXT[], NULL::TEXT[]),
  (ARRAY[]::TEXT[], NULL),
  (ARRAY['serious'], ARRAY['casual']),
  (ARRAY['nonsense'], ARRAY['serious'])
) AS v(x, y);

-- An unknown value behaves like any other non-overlapping one ----------------
SELECT pg_temp.chk(17, 'an unknown value does not crash the gate',
  ARRAY['nonsense'], ARRAY['serious'], TRUE);

-- Symmetry: the gate is evaluated once per pair and must not depend on order.
INSERT INTO results
SELECT 18, 'the rule is symmetric for every pair of the four values',
  CASE WHEN bool_and(
         public.mm_intentions_compatible(ARRAY[i], ARRAY[j])
           = public.mm_intentions_compatible(ARRAY[j], ARRAY[i]))
       THEN 'PASS' ELSE 'FAIL' END
FROM unnest(ARRAY['serious','feeling','talk','casual']) i,
     unnest(ARRAY['serious','feeling','talk','casual']) j;

-- Exactly one of the sixteen single-value pairs is refused, twice (both
-- orders). Pins the blast radius: a change that starts refusing more shows up
-- here rather than as an empty pool in production.
INSERT INTO results
SELECT 19, 'exactly 2 of the 16 single-value pairs are refused',
  CASE WHEN count(*) = 2 THEN 'PASS' ELSE 'FAIL' END
FROM unnest(ARRAY['serious','feeling','talk','casual']) i,
     unnest(ARRAY['serious','feeling','talk','casual']) j
WHERE NOT public.mm_intentions_compatible(ARRAY[i], ARRAY[j]);

SELECT lpad(n::text, 2) AS "#", status, name FROM results ORDER BY n;
