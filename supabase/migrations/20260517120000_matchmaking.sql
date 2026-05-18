-- =============================================================================
-- DateNow — Instant matchmaking
--
-- A real-time queue: a user "searching" inserts a row; clients read the
-- queue, score peers with the existing MatchingService (client-side),
-- then call `claim_match` to atomically pair up.
--
-- `public.calls` already plays the role of the video session table
-- (channel_name / status / caller_id / callee_id / ended_*), so we do
-- NOT create a separate `video_sessions` — `claim_match` writes a calls
-- row directly.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.matchmaking_queue (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     UUID NOT NULL UNIQUE
                REFERENCES public.profiles(id) ON DELETE CASCADE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS matchmaking_queue_created_idx
  ON public.matchmaking_queue(created_at);

ALTER TABLE public.matchmaking_queue ENABLE ROW LEVEL SECURITY;

-- Any authenticated user can read the queue (needed to discover peers).
DROP POLICY IF EXISTS "mq_select_authenticated" ON public.matchmaking_queue;
CREATE POLICY "mq_select_authenticated"
  ON public.matchmaking_queue FOR SELECT
  USING (auth.uid() IS NOT NULL);

-- A user manages only their own queue row.
DROP POLICY IF EXISTS "mq_modify_own" ON public.matchmaking_queue;
CREATE POLICY "mq_modify_own"
  ON public.matchmaking_queue FOR ALL
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

-- Realtime so a client sees peers entering/leaving the queue live.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename = 'matchmaking_queue'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.matchmaking_queue;
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- claim_match(peer_id)
--
-- Called by the client once it has locally scored `peer_id` at >= 75 %.
-- Atomically: if an active call for the pair already exists, return it;
-- otherwise create a fresh calls row + channel_name and pull both users
-- out of the queue. SECURITY DEFINER so it can write the calls row and
-- delete the peer's queue entry.
--
-- Returns the calls row as JSONB.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.claim_match(peer_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me        UUID := auth.uid();
  existing  public.calls;
  fresh     public.calls;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'unauthenticated';
  END IF;
  IF me = peer_id THEN
    RAISE EXCEPTION 'cannot match self';
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

  -- Create the session, then derive channel_name from its id.
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
