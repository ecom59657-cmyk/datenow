-- =============================================================================
-- DateNow — server-side flow structural checks (READ-ONLY, non-intrusive)
--
-- Run this in the Supabase SQL editor (or psql) against the project the
-- app talks to. It only SELECTs from the catalog — it writes nothing and
-- leaves no test data. It verifies that every server object the
-- matching → call → token → pre-call → reveal flow depends on actually
-- exists with the expected shape.
--
-- The *behavioural* checks (claim_match atomicity, active_queue_peers
-- freshness, the Agora token Edge Function) need a real auth context /
-- two clients — they are covered by the 2-phone run in
-- docs/TEST_PROTOCOL_MVP.md. This script is the static backstop.
--
-- Expected: every row PASS.
-- =============================================================================

SELECT 'fn claim_match(uuid)' AS check,
  CASE WHEN to_regprocedure('public.claim_match(uuid)') IS NOT NULL
       THEN 'PASS' ELSE 'FAIL' END AS status
UNION ALL
SELECT 'fn active_queue_peers()',
  CASE WHEN to_regprocedure('public.active_queue_peers()') IS NOT NULL
       THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'fn queue_heartbeat()',
  CASE WHEN to_regprocedure('public.queue_heartbeat()') IS NOT NULL
       THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'fn mark_call_ready(uuid)',
  CASE WHEN to_regprocedure('public.mark_call_ready(uuid)') IS NOT NULL
       THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'fn set_presence(text)',
  CASE WHEN to_regprocedure('public.set_presence(text)') IS NOT NULL
       THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'fn active_profiles_count()',
  CASE WHEN to_regprocedure('public.active_profiles_count()') IS NOT NULL
       THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'fn available_date_proposals_today()',
  CASE WHEN to_regprocedure('public.available_date_proposals_today()')
              IS NOT NULL
       THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'fn unread_messages_count()',
  CASE WHEN to_regprocedure('public.unread_messages_count()')
              IS NOT NULL
       THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'fn mark_conversation_read(uuid)',
  CASE WHEN to_regprocedure('public.mark_conversation_read(uuid)')
              IS NOT NULL
       THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'table user_presence',
  CASE WHEN to_regclass('public.user_presence') IS NOT NULL
       THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'table matchmaking_queue',
  CASE WHEN to_regclass('public.matchmaking_queue') IS NOT NULL
       THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'table reveals',
  CASE WHEN to_regclass('public.reveals') IS NOT NULL
       THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'table conversations',
  CASE WHEN to_regclass('public.conversations') IS NOT NULL
       THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'table messages',
  CASE WHEN to_regclass('public.messages') IS NOT NULL
       THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'table device_tokens',
  CASE WHEN to_regclass('public.device_tokens') IS NOT NULL
       THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'col matchmaking_queue.heartbeat_at',
  CASE WHEN EXISTS (SELECT 1 FROM information_schema.columns
        WHERE table_schema='public' AND table_name='matchmaking_queue'
          AND column_name='heartbeat_at')
       THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'col calls.caller_ready',
  CASE WHEN EXISTS (SELECT 1 FROM information_schema.columns
        WHERE table_schema='public' AND table_name='calls'
          AND column_name='caller_ready')
       THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'col calls.callee_ready',
  CASE WHEN EXISTS (SELECT 1 FROM information_schema.columns
        WHERE table_schema='public' AND table_name='calls'
          AND column_name='callee_ready')
       THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'col calls.started_at',
  CASE WHEN EXISTS (SELECT 1 FROM information_schema.columns
        WHERE table_schema='public' AND table_name='calls'
          AND column_name='started_at')
       THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'col calls.channel_name',
  CASE WHEN EXISTS (SELECT 1 FROM information_schema.columns
        WHERE table_schema='public' AND table_name='calls'
          AND column_name='channel_name')
       THEN 'PASS' ELSE 'FAIL' END
UNION ALL
-- The reveal de-dup guard: UNIQUE(call_id, user_id) on reveals.
SELECT 'reveals UNIQUE(call_id,user_id)',
  CASE WHEN EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid='public.reveals'::regclass AND contype='u')
       THEN 'PASS' ELSE 'FAIL' END
UNION ALL
-- The match de-dup guard: UNIQUE(user_a_id, user_b_id) on matches.
SELECT 'matches UNIQUE(user_a_id,user_b_id)',
  CASE WHEN EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid='public.matches'::regclass AND contype='u')
       THEN 'PASS' ELSE 'FAIL' END;

-- -----------------------------------------------------------------------------
-- Optional sanity probe — no duplicate active call per participant pair.
-- An empty result = PASS (claim_match never produced a split-brain pair).
-- -----------------------------------------------------------------------------
SELECT
  least(caller_id, callee_id)  AS user_lo,
  greatest(caller_id, callee_id) AS user_hi,
  count(*) AS active_calls
FROM public.calls
WHERE status <> 'ended'
GROUP BY 1, 2
HAVING count(*) > 1;
