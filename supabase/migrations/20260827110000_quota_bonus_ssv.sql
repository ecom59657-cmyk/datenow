-- =============================================================================
-- DateNow — the rewarded bonus becomes unforgeable
--
-- 20260827100000 shipped grant_quota_bonus() callable by the signed-in user,
-- with a ceiling of three a day so a repackaged client could mint at most
-- three free dates instead of an endless supply. Bounded, but still a client
-- being taken at its word about whether it watched a video.
--
-- AdMob server-side verification removes the word. Google calls our endpoint
-- itself, signs the call with a rotating ECDSA key, and only does so once the
-- user actually earned the reward. Closing the video early produces no
-- callback and therefore no date.
--
-- After this migration the only writers into quota_bonuses are:
--
--   * the admob-ssv Edge Function, holding the service_role key
--   * a human with database access, for support
--
-- ⚠ DEPLOY ORDER MATTERS. The client can no longer grant itself anything the
--   moment this lands, so the SSV callback URL must already be configured in
--   the AdMob console (Ad unit → Rewarded → Server-side verification) or the
--   bonus silently stops working. See docs/ADMOB_SSV.md.
-- =============================================================================

-- ── The client loses the right to pay itself ─────────────────────────
--
-- Kept, not dropped: support still needs a way to hand someone a date back
-- when a callback is lost, and service_role can still call it.
REVOKE EXECUTE ON FUNCTION public.grant_quota_bonus() FROM authenticated;

COMMENT ON FUNCTION public.grant_quota_bonus() IS
  'Grants the caller one extra date for today, up to three. NO LONGER '
  'EXECUTABLE BY authenticated — the client cannot vouch for itself since '
  'AdMob SSV landed. Reachable by service_role for support only.';

-- ── The verified path ────────────────────────────────────────────────
--
-- Called by the admob-ssv Edge Function once Google's signature checks out.
-- Takes the user id as an argument — there is no auth.uid() in a callback
-- from Google — which is exactly why it must never be granted to
-- authenticated: that would let anyone name anyone.
CREATE OR REPLACE FUNCTION public.grant_quota_bonus_ssv(
  p_user_id        UUID,
  p_transaction_id TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_day   DATE;
  v_count INT;
  v_id    UUID;
  c_max   CONSTANT INT := 3;
BEGIN
  IF p_user_id IS NULL OR p_transaction_id IS NULL OR p_transaction_id = '' THEN
    RAISE EXCEPTION 'missing_argument' USING ERRCODE = '22023';
  END IF;

  -- The user must exist. Google echoes back whatever string the app put in
  -- ServerSideVerificationOptions.userId, and a stale install could send an
  -- id that no longer resolves.
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = p_user_id) THEN
    RETURN jsonb_build_object('granted', false, 'reason', 'unknown_user');
  END IF;

  v_day := public.quota_day();

  -- Replay first, ceiling second. Google retries a callback it could not
  -- deliver, and a retry must be a no-op rather than a refusal — otherwise a
  -- redelivery on a full day would look like a failure and be retried again.
  SELECT id INTO v_id
    FROM public.quota_bonuses
   WHERE ssv_transaction_id = p_transaction_id;

  IF v_id IS NOT NULL THEN
    RETURN jsonb_build_object('granted', true, 'replay', true);
  END IF;

  SELECT count(*) INTO v_count
    FROM public.quota_bonuses
   WHERE user_id = p_user_id
     AND granted_on = v_day;

  IF v_count >= c_max THEN
    RETURN jsonb_build_object(
      'granted', false,
      'reason', 'daily_bonus_limit',
      'bonus_today', v_count
    );
  END IF;

  -- ON CONFLICT covers the race two simultaneous deliveries would otherwise
  -- win: the unique partial index on ssv_transaction_id is the real guard,
  -- the SELECT above is just the cheap path.
  INSERT INTO public.quota_bonuses
    (user_id, granted_on, source, ssv_transaction_id, verified)
  VALUES
    (p_user_id, v_day, 'rewarded_ad', p_transaction_id, true)
  ON CONFLICT (ssv_transaction_id) WHERE ssv_transaction_id IS NOT NULL
  DO NOTHING;

  RETURN jsonb_build_object(
    'granted', true,
    'replay', false,
    'bonus_today', v_count + 1
  );
END;
$$;

-- No authenticated grant, on purpose. Anyone who could call this could name
-- someone else's user id.
REVOKE ALL ON FUNCTION public.grant_quota_bonus_ssv(UUID, TEXT) FROM PUBLIC;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.grant_quota_bonus_ssv(UUID, TEXT)
             TO service_role';
  END IF;
END $$;

COMMENT ON FUNCTION public.grant_quota_bonus_ssv(UUID, TEXT) IS
  'Writes a verified rewarded-ad bonus after AdMob''s signed callback. '
  'Idempotent on the transaction id so a redelivery never pays twice. '
  'service_role only — never grant to authenticated.';
