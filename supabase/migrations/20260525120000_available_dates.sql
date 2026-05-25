-- =============================================================================
-- DateNow — "dates proposés aujourd'hui" stat + busy-peer guard
--
--  * available_date_proposals_today() — count surfaced on the Home card,
--    backing the FR copy "4 dates proposés aujourd'hui". It only counts
--    peers who are reachable RIGHT NOW: fresh presence, not banned, not
--    moderation-suspended, not already in another live call, and not on
--    either side of a block. Hides the caller.
--
--  * claim_match() — extended with a peer_busy gate so a manipulated
--    client cannot claim someone who is already on another live date.
--    Returns the same JSONB shape as before for the happy path; raises
--    `peer_busy` for the new failure case.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 0. Defensive: re-create blocked_users if the remote is missing it
--
-- The initial schema declared this table, but at least one remote has
-- 20260513120000 marked applied without the table actually present
-- (initial file was extended after first apply — same drift we saw for
-- `reports` and `matches`). The RPC below references it, so guarantee
-- it exists with IF NOT EXISTS + the original constraints + RLS.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.blocked_users (
  user_id          UUID NOT NULL
                     REFERENCES public.profiles(id) ON DELETE CASCADE,
  blocked_user_id  UUID NOT NULL
                     REFERENCES public.profiles(id) ON DELETE CASCADE,
  blocked_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  reason           TEXT,

  PRIMARY KEY (user_id, blocked_user_id),
  CONSTRAINT no_self_block CHECK (user_id <> blocked_user_id)
);

ALTER TABLE public.blocked_users ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "blocked_users_all_owner" ON public.blocked_users;
CREATE POLICY "blocked_users_all_owner"
  ON public.blocked_users FOR ALL
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

-- -----------------------------------------------------------------------------
-- 1. available_date_proposals_today()
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.available_date_proposals_today()
RETURNS INTEGER
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT count(*)::int
  FROM public.user_presence p
  JOIN public.profiles prof ON prof.id = p.user_id
  WHERE p.user_id <> auth.uid()
    -- 1. Reachable: online or actively searching, with a fresh heartbeat.
    AND p.status IN ('online', 'searching')
    AND p.updated_at > now() - interval '60 seconds'
    -- 2. Not banned / suspended.
    AND COALESCE(prof.is_banned, false) = false
    AND COALESCE(prof.moderation_status, 'active') = 'active'
    -- 3. Not blocked in either direction.
    AND NOT EXISTS (
      SELECT 1 FROM public.blocked_users b
      WHERE (b.user_id = auth.uid() AND b.blocked_user_id = p.user_id)
         OR (b.user_id = p.user_id   AND b.blocked_user_id = auth.uid())
    )
    -- 4. Not currently in another live call (with anyone).
    AND NOT EXISTS (
      SELECT 1 FROM public.calls c
      WHERE (c.caller_id = p.user_id OR c.callee_id = p.user_id)
        AND c.status <> 'ended'
    );
$$;

GRANT EXECUTE ON FUNCTION public.available_date_proposals_today() TO authenticated;

-- -----------------------------------------------------------------------------
-- 2. claim_match() — refuse if the peer is already busy
--
-- Existing behaviour kept verbatim (auth check, self check, ban check,
-- reuse-existing-pair, fresh insert). New gate raises `peer_busy` when
-- the requested peer is in a live call with a THIRD party — without
-- this, two clients fighting over the same target could end up in
-- separate ghost calls.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.claim_match(peer_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me           UUID := auth.uid();
  me_banned    BOOLEAN;
  peer_banned  BOOLEAN;
  existing     public.calls;
  fresh        public.calls;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'unauthenticated';
  END IF;
  IF me = peer_id THEN
    RAISE EXCEPTION 'cannot match self';
  END IF;

  SELECT is_banned INTO me_banned   FROM public.profiles WHERE id = me;
  IF COALESCE(me_banned, false) THEN
    RAISE EXCEPTION 'account_suspended';
  END IF;

  SELECT is_banned INTO peer_banned FROM public.profiles WHERE id = peer_id;
  IF COALESCE(peer_banned, false) THEN
    RAISE EXCEPTION 'peer_unavailable';
  END IF;

  -- Already paired? Reuse the live session — keeps both peers on the
  -- same call when they claim each other near-simultaneously.
  SELECT * INTO existing
  FROM public.calls c
  WHERE ((c.caller_id = me AND c.callee_id = peer_id)
      OR (c.caller_id = peer_id AND c.callee_id = me))
    AND c.status <> 'ended'
  ORDER BY c.started_at DESC
  LIMIT 1;

  IF FOUND THEN
    DELETE FROM public.matchmaking_queue WHERE user_id IN (me, peer_id);
    RETURN to_jsonb(existing);
  END IF;

  -- Peer already on another live call (with someone else)? Refuse so
  -- two parallel calls for the same person never coexist.
  IF EXISTS (
    SELECT 1 FROM public.calls c
    WHERE (c.caller_id = peer_id OR c.callee_id = peer_id)
      AND c.status <> 'ended'
  ) THEN
    RAISE EXCEPTION 'peer_busy';
  END IF;

  -- Fresh insert; channel_name derived from the new row's id.
  INSERT INTO public.calls (caller_id, callee_id, status)
  VALUES (me, peer_id, 'live')
  RETURNING * INTO fresh;

  UPDATE public.calls
  SET channel_name = 'dn_' || fresh.id
  WHERE id = fresh.id
  RETURNING * INTO fresh;

  DELETE FROM public.matchmaking_queue WHERE user_id IN (me, peer_id);
  RETURN to_jsonb(fresh);
END;
$$;

GRANT EXECUTE ON FUNCTION public.claim_match(UUID) TO authenticated;
