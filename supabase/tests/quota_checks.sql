-- =============================================================================
-- DateNow — server-side quota, structural checks (READ-ONLY)
--
-- Safe to run anywhere, including production: it only reads the catalog and
-- calls one pure function. It writes nothing and leaves nothing behind.
--
-- The behavioural half — caps per tier, what counts as consumption, the bonus
-- ceiling — needs seeded users and a switchable auth.uid(), so it lives in
-- scripts/test_quota_sql.sh against a throwaway Postgres.
--
-- Expected: every row PASS.
-- =============================================================================

SELECT 'fn quota_fnv1a(text)' AS check,
  CASE WHEN to_regprocedure('public.quota_fnv1a(text)') IS NOT NULL
       THEN 'PASS' ELSE 'FAIL' END AS status
UNION ALL
SELECT 'fn quota_day()',
  CASE WHEN to_regprocedure('public.quota_day()') IS NOT NULL
       THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'fn quota_status()',
  CASE WHEN to_regprocedure('public.quota_status()') IS NOT NULL
       THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'fn grant_quota_bonus()',
  CASE WHEN to_regprocedure('public.grant_quota_bonus()') IS NOT NULL
       THEN 'PASS' ELSE 'FAIL' END
UNION ALL
-- SECURITY DEFINER is what lets these read another schema's rows; without it
-- RLS would hide the caller's own counters from the function.
SELECT 'quota_status is SECURITY DEFINER',
  CASE WHEN (SELECT prosecdef FROM pg_proc
              WHERE oid = 'public.quota_status()'::regprocedure)
       THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'grant_quota_bonus is SECURITY DEFINER',
  CASE WHEN (SELECT prosecdef FROM pg_proc
              WHERE oid = 'public.grant_quota_bonus()'::regprocedure)
       THEN 'PASS' ELSE 'FAIL' END
UNION ALL
-- A SECURITY DEFINER function with a mutable search_path is a privilege
-- escalation waiting for someone to create public.calls in their own schema.
SELECT 'quota_status pins search_path',
  CASE WHEN EXISTS (SELECT 1 FROM pg_proc
                     WHERE oid = 'public.quota_status()'::regprocedure
                       AND array_to_string(proconfig, ',') LIKE '%search_path%')
       THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'table quota_bonuses',
  CASE WHEN to_regclass('public.quota_bonuses') IS NOT NULL
       THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'quota_bonuses has RLS enabled',
  CASE WHEN (SELECT relrowsecurity FROM pg_class
              WHERE oid = 'public.quota_bonuses'::regclass)
       THEN 'PASS' ELSE 'FAIL' END
UNION ALL
-- The whole anti-forgery stance rests on this: no INSERT policy means the
-- only writers are the definer function and the service_role key.
SELECT 'quota_bonuses has NO write policy',
  CASE WHEN NOT EXISTS (
         SELECT 1 FROM pg_policies
          WHERE schemaname = 'public' AND tablename = 'quota_bonuses'
            AND cmd IN ('INSERT', 'UPDATE', 'DELETE', 'ALL'))
       THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'quota_bonuses select policy is scoped to auth.uid()',
  CASE WHEN EXISTS (
         SELECT 1 FROM pg_policies
          WHERE schemaname = 'public' AND tablename = 'quota_bonuses'
            AND cmd = 'SELECT' AND qual LIKE '%auth.uid()%')
       THEN 'PASS' ELSE 'FAIL' END
UNION ALL
-- A signed AdMob callback can arrive twice. Replaying it must not pay twice.
SELECT 'ssv transaction id is unique',
  CASE WHEN EXISTS (SELECT 1 FROM pg_indexes
                     WHERE schemaname = 'public'
                       AND tablename = 'quota_bonuses'
                       AND indexdef LIKE '%UNIQUE%ssv_transaction_id%')
       THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'quota_bonuses (user_id, granted_on) index',
  CASE WHEN EXISTS (SELECT 1 FROM pg_indexes
                     WHERE tablename = 'quota_bonuses'
                       AND indexdef LIKE '%user_id, granted_on%')
       THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'calls (caller_id, started_at) index',
  CASE WHEN EXISTS (SELECT 1 FROM pg_indexes
                     WHERE tablename = 'calls'
                       AND indexdef LIKE '%caller_id, started_at%')
       THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'calls (callee_id, started_at) index',
  CASE WHEN EXISTS (SELECT 1 FROM pg_indexes
                     WHERE tablename = 'calls'
                       AND indexdef LIKE '%callee_id, started_at%')
       THEN 'PASS' ELSE 'FAIL' END
UNION ALL
-- ── Hash parity with Dart ────────────────────────────────────────────
-- These three literals are produced by QuotaService's FNV-1a. If Postgres
-- disagrees, the server and the client hand out the boost on different days
-- and the user sees a cap that changes when the app reloads.
SELECT 'fnv1a(''a'') matches Dart',
  CASE WHEN public.quota_fnv1a('a') = 3826002220
       THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'fnv1a(''datenow'') matches Dart',
  CASE WHEN public.quota_fnv1a('datenow') = 587590907
       THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'fnv1a(day key) matches Dart',
  CASE WHEN public.quota_fnv1a(
         '0000000a-0000-4000-8000-000000000003:2026-08-27') = 801266412
       THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'fnv1a stays inside 32 bits',
  CASE WHEN public.quota_fnv1a(repeat('x', 500)) BETWEEN 0 AND 4294967295
       THEN 'PASS' ELSE 'FAIL' END
UNION ALL
-- ── After AdMob SSV: the client cannot pay itself ────────────────────
SELECT 'fn grant_quota_bonus_ssv(uuid,text)',
  CASE WHEN to_regprocedure('public.grant_quota_bonus_ssv(uuid,text)') IS NOT NULL
       THEN 'PASS' ELSE 'FAIL' END
UNION ALL
-- The single most important row in this file. If it goes green→red, the app
-- can grant itself dates again and "you must watch the video" is over.
SELECT 'authenticated CANNOT call grant_quota_bonus',
  CASE WHEN NOT has_function_privilege(
              'authenticated', 'public.grant_quota_bonus()', 'EXECUTE')
       THEN 'PASS' ELSE 'FAIL' END
UNION ALL
-- This one takes a user id as an argument; reachable by a client, it would
-- let anyone credit anyone.
SELECT 'authenticated CANNOT call grant_quota_bonus_ssv',
  CASE WHEN NOT has_function_privilege(
              'authenticated', 'public.grant_quota_bonus_ssv(uuid,text)', 'EXECUTE')
       THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'authenticated CAN still read its own quota',
  CASE WHEN has_function_privilege(
              'authenticated', 'public.quota_status()', 'EXECUTE')
       THEN 'PASS' ELSE 'FAIL' END
UNION ALL
-- Europe/Paris, not UTC: a cap that rolls over at 02:00 local is a bug.
SELECT 'quota_day() is the Paris date',
  CASE WHEN public.quota_day() = (now() AT TIME ZONE 'Europe/Paris')::date
       THEN 'PASS' ELSE 'FAIL' END;
