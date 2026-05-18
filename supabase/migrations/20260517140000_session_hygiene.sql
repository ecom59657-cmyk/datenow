-- =============================================================================
-- DateNow — Session hygiene
--
-- Anti-abandon plumbing:
--   * matchmaking_queue.heartbeat_at — a searching client refreshes it
--     every ~12 s; peers whose heartbeat is stale (app crashed / killed)
--     are ignored by the matcher and never block anyone.
--   * queue_heartbeat() / active_queue_peers() run server-side so there's
--     no client clock skew on the freshness window.
-- =============================================================================

ALTER TABLE public.matchmaking_queue
  ADD COLUMN IF NOT EXISTS heartbeat_at TIMESTAMPTZ NOT NULL DEFAULT now();

-- Refresh the caller's own heartbeat (server clock).
CREATE OR REPLACE FUNCTION public.queue_heartbeat()
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  UPDATE public.matchmaking_queue
  SET heartbeat_at = now()
  WHERE user_id = auth.uid();
$$;

GRANT EXECUTE ON FUNCTION public.queue_heartbeat() TO authenticated;

-- User ids of peers currently searching with a fresh heartbeat
-- (< 30 s old). Excludes the caller. Server-side so stale rows are
-- filtered with the DB clock, not the client's.
CREATE OR REPLACE FUNCTION public.active_queue_peers()
RETURNS SETOF UUID
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT user_id
  FROM public.matchmaking_queue
  WHERE user_id <> auth.uid()
    AND heartbeat_at > now() - interval '30 seconds';
$$;

GRANT EXECUTE ON FUNCTION public.active_queue_peers() TO authenticated;
