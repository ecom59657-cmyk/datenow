-- =============================================================================
-- DateNow — Match-decision reciprocity (the missing half of mutual reveal)
--
-- Before this migration, a `reveals` row only tracked the **photo reveal**
-- step (`revealed: bool`). Once both peers had revealed and the mutual
-- view appeared with the Match / Pass buttons, the first user to tap
-- "Je veux matcher" caused the client to:
--   * write the permanent `matches` row,
--   * create the `conversations` row,
--   * flip the local UI to "matched"
-- *without waiting for the peer's decision*. The peer's tap was never
-- verified, so the match (and the chat) existed even if the peer chose
-- "Passer". Product rule violated: there must be no chat without both
-- users explicitly choosing match.
--
-- Fix: a per-user `decision` column on `reveals` (pending / match / pass)
-- captured for each side of a call. The client only writes the match +
-- conversation once it sees both rows resolve to `decision = 'match'`.
-- Either user picking `pass` short-circuits to a no-match outcome.
-- =============================================================================

ALTER TABLE public.reveals
  ADD COLUMN IF NOT EXISTS decision TEXT NOT NULL DEFAULT 'pending';

ALTER TABLE public.reveals
  DROP CONSTRAINT IF EXISTS reveals_decision_check;
ALTER TABLE public.reveals
  ADD CONSTRAINT reveals_decision_check
  CHECK (decision IN ('pending', 'match', 'pass'));

-- Realtime is already publishing public.reveals (matched by realtime
-- ADD TABLE in 20260517130000_reveals.sql) so column updates flow to
-- both peers' watchers without further config.

-- Optional index — the client always filters by call_id, but a
-- composite (call_id, user_id) is already covered by the existing
-- UNIQUE constraint, so no extra index is needed.
