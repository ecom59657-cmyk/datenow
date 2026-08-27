-- =============================================================================
-- DateNow — the daily quota, decided by the server
--
-- Until now the cap lived entirely in the Flutter process: MockQuotaRepository
-- held a Map, SupabaseQuotaRepository raised UnimplementedError, and the whole
-- thing reset when the app was killed. Anyone could have unlimited dates by
-- force-quitting. This migration moves the decision to Postgres, where the
-- client cannot argue with it.
--
-- Three numbers make up a day's allowance:
--
--   cap    3 for a free man, 6 for a paying one, NULL (unlimited) for
--          everyone else. Read from subscriptions.tier, not from the client.
--   bonus  +1 per rewarded video actually watched, capped per day.
--   boost  +1 on roughly one day in four, as a gift.
--
-- Two things worth knowing before reading further:
--
--  * **Consumption is derived, never written.** public.calls already records
--    every date; counting it means no second source of truth to keep in sync,
--    and it closes a live bug — the Home "Lancer un date" button never called
--    recordMatch at all, so its dates were free.
--
--  * **Both participants are charged.** In find_best_live_candidate the row is
--    INSERTed as (me, peer_id) by whichever of the two polled first — both had
--    tapped the button, so caller_id is arbitrary. Charging only the caller
--    would bill a coin flip.
--
-- The day boundary is Europe/Paris, not UTC and not the device's clock: the
-- product ships in France, and a cap that rolls over at 02:00 local would be
-- its own bug report.
-- =============================================================================

-- ── FNV-1a, byte for byte the hash the Dart client uses ──────────────
--
-- The boost has to feel random and be reproducible: a real random() would
-- re-roll on every read, so the allowance would flicker between two taps and
-- pulling to refresh would mint dates. Deterministic from (user, day) means
-- the server and the client always agree, and nothing has to be stored.
--
-- Mirrors QuotaService._isBoostedDay in lib/features/quota/data/quota_service.dart.
-- If one side changes, quota_checks.sql fails.
CREATE OR REPLACE FUNCTION public.quota_fnv1a(p_key TEXT)
RETURNS BIGINT
LANGUAGE plpgsql
IMMUTABLE
SET search_path = public
AS $$
DECLARE
  h BIGINT := 2166136261;   -- 0x811c9dc5, the FNV offset basis
  i INT;
BEGIN
  FOR i IN 1..length(p_key) LOOP
    h := h # ascii(substr(p_key, i, 1));
    h := (h * 16777619) & 4294967295;   -- 0x01000193, truncated to 32 bits
  END LOOP;
  RETURN h;
END;
$$;

COMMENT ON FUNCTION public.quota_fnv1a(TEXT) IS
  'FNV-1a 32-bit over a UTF-8/ASCII key. Kept byte-identical to the Dart '
  'implementation in QuotaService so the daily boost is the same number on '
  'both sides. Not a security primitive — do not use it for anything secret.';

-- ── The day a quota hangs off ─────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.quota_day()
RETURNS DATE
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT (now() AT TIME ZONE 'Europe/Paris')::date;
$$;

COMMENT ON FUNCTION public.quota_day() IS
  'Today in Europe/Paris. The quota rolls over at local midnight for the '
  'market the app ships in, rather than at UTC midnight (02:00 in summer).';

-- ── quota_bonuses — the +1 a rewarded video buys ──────────────────────
--
-- One row per granted bonus. Rows are never written by the client directly:
-- there is deliberately no INSERT policy, so the only ways in are the
-- SECURITY DEFINER function below and the service_role key held by the
-- (future) AdMob SSV Edge Function.
CREATE TABLE IF NOT EXISTS public.quota_bonuses (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  granted_on   DATE NOT NULL DEFAULT (now() AT TIME ZONE 'Europe/Paris')::date,
  source       TEXT NOT NULL DEFAULT 'rewarded_ad'
                 CHECK (source IN ('rewarded_ad')),
  -- AdMob's server-side-verification transaction id, once that lands. NULL
  -- means the grant was taken on the client's word; the UNIQUE index below
  -- makes a verified grant impossible to replay.
  ssv_transaction_id TEXT,
  verified     BOOLEAN NOT NULL DEFAULT false,
  granted_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- The read the status function makes on every quota check.
CREATE INDEX IF NOT EXISTS quota_bonuses_user_day_idx
  ON public.quota_bonuses (user_id, granted_on);

-- A signed AdMob callback can be delivered more than once. Replaying it must
-- not pay twice.
CREATE UNIQUE INDEX IF NOT EXISTS quota_bonuses_ssv_txn_idx
  ON public.quota_bonuses (ssv_transaction_id)
  WHERE ssv_transaction_id IS NOT NULL;

ALTER TABLE public.quota_bonuses ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS quota_bonuses_select_own ON public.quota_bonuses;
CREATE POLICY quota_bonuses_select_own ON public.quota_bonuses
  FOR SELECT TO authenticated
  USING (user_id = (SELECT auth.uid()));

COMMENT ON TABLE public.quota_bonuses IS
  'Extra dates earned by watching a rewarded video. Read-only to the owner; '
  'writes go through public.grant_quota_bonus() or the service_role key. '
  'No INSERT policy exists on purpose.';

-- ── Composite indexes for the daily count ─────────────────────────────
--
-- The existing calls_caller_idx / calls_callee_idx are single-column, so the
-- date range is a filter after the fetch. On a busy account that reads far
-- more rows than the day needs.
CREATE INDEX IF NOT EXISTS calls_caller_started_idx
  ON public.calls (caller_id, started_at DESC);
CREATE INDEX IF NOT EXISTS calls_callee_started_idx
  ON public.calls (callee_id, started_at DESC);

-- ── quota_status() — the one answer the client is allowed to ask for ──
CREATE OR REPLACE FUNCTION public.quota_status()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me        UUID := auth.uid();
  v_day     DATE;
  v_start   TIMESTAMPTZ;
  v_end     TIMESTAMPTZ;
  v_gender  TEXT;
  v_premium BOOLEAN;
  v_cap     INT;
  v_used    INT;
  v_bonus   INT;
  v_boost   INT;
BEGIN
  -- SECURITY DEFINER bypasses RLS, so the caller's identity is the only
  -- thing standing between one user and another's counters. Never widen
  -- this function to take a user_id argument.
  IF me IS NULL THEN
    RAISE EXCEPTION 'not_authenticated' USING ERRCODE = '28000';
  END IF;

  v_day   := public.quota_day();
  v_start := v_day::timestamp AT TIME ZONE 'Europe/Paris';
  v_end   := (v_day + 1)::timestamp AT TIME ZONE 'Europe/Paris';

  SELECT gender INTO v_gender FROM public.profiles WHERE id = me;

  SELECT EXISTS (
    SELECT 1 FROM public.subscriptions
     WHERE user_id = me
       AND tier = 'premium'
       AND (active_until IS NULL OR active_until > now())
  ) INTO v_premium;

  -- Only men are capped. The scarce side of a dating marketplace is not the
  -- side worth rationing.
  IF v_gender = 'male' THEN
    v_cap := CASE WHEN v_premium THEN 6 ELSE 3 END;
  ELSE
    v_cap := NULL;
  END IF;

  SELECT count(*) INTO v_used
    FROM public.calls
   WHERE (caller_id = me OR callee_id = me)
     AND started_at >= v_start
     AND started_at <  v_end;

  SELECT count(*) INTO v_bonus
    FROM public.quota_bonuses
   WHERE user_id = me
     AND granted_on = v_day;

  -- A boost on top of infinity is nothing, so unlimited users get none —
  -- and reporting one would be a lie in the analytics.
  IF v_cap IS NULL THEN
    v_boost := 0;
  ELSE
    v_boost := CASE
      WHEN public.quota_fnv1a(me::text || ':' || to_char(v_day, 'YYYY-MM-DD')) % 4 = 0
      THEN 1 ELSE 0
    END;
  END IF;

  RETURN jsonb_build_object(
    'day',         to_char(v_day, 'YYYY-MM-DD'),
    'used_today',  v_used,
    'cap',         v_cap,          -- null = unlimited
    'bonus_today', v_bonus,
    'boost_today', v_boost,
    'is_premium',  v_premium
  );
END;
$$;

REVOKE ALL ON FUNCTION public.quota_status() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.quota_status() TO authenticated;

COMMENT ON FUNCTION public.quota_status() IS
  'Today''s allowance for the caller: dates consumed, base cap, ad bonuses '
  'and the daily boost. Consumption is derived from public.calls counting '
  'both participants; the cap is read from subscriptions, never from the '
  'client. Always scoped to auth.uid().';

-- ── grant_quota_bonus() — one date for one watched video ──────────────
--
-- The client calls this after Google reports the reward earned. A repackaged
-- app could call it without watching, which is why the daily ceiling exists:
-- forging it buys at most three dates, not an unbounded supply. The
-- unforgeable version is AdMob server-side verification, which will write
-- these rows with verified = true and an ssv_transaction_id.
CREATE OR REPLACE FUNCTION public.grant_quota_bonus()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me      UUID := auth.uid();
  v_day   DATE;
  v_count INT;
  c_max   CONSTANT INT := 3;   -- ceiling per day, matches the free cap
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'not_authenticated' USING ERRCODE = '28000';
  END IF;

  v_day := public.quota_day();

  SELECT count(*) INTO v_count
    FROM public.quota_bonuses
   WHERE user_id = me
     AND granted_on = v_day;

  IF v_count >= c_max THEN
    RETURN jsonb_build_object(
      'granted', false,
      'reason',  'daily_bonus_limit',
      'bonus_today', v_count
    );
  END IF;

  INSERT INTO public.quota_bonuses (user_id, granted_on, source)
  VALUES (me, v_day, 'rewarded_ad');

  RETURN jsonb_build_object(
    'granted', true,
    'bonus_today', v_count + 1
  );
END;
$$;

REVOKE ALL ON FUNCTION public.grant_quota_bonus() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.grant_quota_bonus() TO authenticated;

COMMENT ON FUNCTION public.grant_quota_bonus() IS
  'Grants the caller one extra date for today, up to three. Returns '
  '{granted, bonus_today} or {granted:false, reason:daily_bonus_limit}. '
  'Client-trusted until AdMob SSV lands — the ceiling bounds the damage.';
