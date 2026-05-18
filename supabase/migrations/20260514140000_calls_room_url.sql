-- =============================================================================
-- DateNow — Daily.co integration
--
-- Daily.co rooms are server-provisioned per call; we store the resulting
-- `room_url` on the call row so both peers join the exact same URL the
-- Edge Function returned to whoever opened the call first.
-- =============================================================================

ALTER TABLE public.calls
  ADD COLUMN IF NOT EXISTS room_url TEXT;
