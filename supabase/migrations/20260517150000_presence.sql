-- =============================================================================
-- DateNow — Real-time presence + pre-call ready handshake
--
--  * public.user_presence — a lightweight "what is this user doing right
--    now" row: online / searching / in_call. `offline` is implicit: a
--    presence row whose updated_at has gone stale (the app stopped
--    refreshing it because it was backgrounded / killed).
--  * set_presence() / active_profiles_count() run server-side so the
--    freshness window uses the DB clock, not the client's.
--  * calls.caller_ready / callee_ready — the pre-call handshake. Each
--    peer flips its own flag once its CallScreen is mounted; the call
--    only "joins" when both are ready, which kills the abrupt black
--    screen on entry.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Presence table
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.user_presence (
  user_id     UUID PRIMARY KEY
                REFERENCES public.profiles(id) ON DELETE CASCADE,
  status      TEXT NOT NULL DEFAULT 'online',
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'user_presence_status_check'
      AND conrelid = 'public.user_presence'::regclass
  ) THEN
    ALTER TABLE public.user_presence
      ADD CONSTRAINT user_presence_status_check
      CHECK (status IN ('online', 'searching', 'in_call', 'offline'));
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS user_presence_updated_idx
  ON public.user_presence(updated_at);

ALTER TABLE public.user_presence ENABLE ROW LEVEL SECURITY;

-- Any authenticated user can read presence (the call screen watches the
-- peer's row; matching reads the active count).
DROP POLICY IF EXISTS "presence_select_authenticated" ON public.user_presence;
CREATE POLICY "presence_select_authenticated"
  ON public.user_presence FOR SELECT
  USING (auth.uid() IS NOT NULL);

-- A user manages only their own presence row.
DROP POLICY IF EXISTS "presence_modify_own" ON public.user_presence;
CREATE POLICY "presence_modify_own"
  ON public.user_presence FOR ALL
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

-- Realtime so the call screen sees the peer's status change live.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename = 'user_presence'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.user_presence;
  END IF;
END $$;

-- Upsert the caller's presence (status + server-clock timestamp). Called
-- on a ~20 s cadence while the app is foregrounded so the row stays
-- fresh; a backgrounded / killed app stops calling it and goes stale.
CREATE OR REPLACE FUNCTION public.set_presence(p_status TEXT)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'unauthenticated';
  END IF;
  IF p_status NOT IN ('online', 'searching', 'in_call', 'offline') THEN
    RAISE EXCEPTION 'invalid presence status: %', p_status;
  END IF;
  INSERT INTO public.user_presence (user_id, status, updated_at)
  VALUES (auth.uid(), p_status, now())
  ON CONFLICT (user_id)
  DO UPDATE SET status = EXCLUDED.status, updated_at = now();
END;
$$;

GRANT EXECUTE ON FUNCTION public.set_presence(TEXT) TO authenticated;

-- Approximate number of profiles currently reachable (online or
-- searching) with a fresh heartbeat (< 60 s). Excludes the caller.
CREATE OR REPLACE FUNCTION public.active_profiles_count()
RETURNS INTEGER
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT count(*)::int
  FROM public.user_presence
  WHERE user_id <> auth.uid()
    AND status IN ('online', 'searching')
    AND updated_at > now() - interval '60 seconds';
$$;

GRANT EXECUTE ON FUNCTION public.active_profiles_count() TO authenticated;

-- -----------------------------------------------------------------------------
-- 2. Pre-call ready handshake on calls
-- -----------------------------------------------------------------------------
ALTER TABLE public.calls
  ADD COLUMN IF NOT EXISTS caller_ready BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE public.calls
  ADD COLUMN IF NOT EXISTS callee_ready BOOLEAN NOT NULL DEFAULT false;

-- Flip the caller's own ready flag for a call it participates in. The
-- function picks the right column from auth.uid() so a client can never
-- mark the *peer* ready. SECURITY DEFINER + an explicit participant check.
CREATE OR REPLACE FUNCTION public.mark_call_ready(p_call_id UUID)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me  UUID := auth.uid();
  row public.calls;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'unauthenticated';
  END IF;
  SELECT * INTO row FROM public.calls WHERE id = p_call_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'call not found';
  END IF;
  IF me = row.caller_id THEN
    UPDATE public.calls SET caller_ready = true WHERE id = p_call_id;
  ELSIF me = row.callee_id THEN
    UPDATE public.calls SET callee_ready = true WHERE id = p_call_id;
  ELSE
    RAISE EXCEPTION 'not a participant of this call';
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.mark_call_ready(UUID) TO authenticated;
