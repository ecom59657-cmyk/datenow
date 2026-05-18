-- =============================================================================
-- DateNow — Post-call mutual reveal
--
-- After the 5-minute blurred call, each participant records a `reveal`
-- decision. The HD photo / permanent match unlock ONLY when both rows
-- have `revealed = true`.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.reveals (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  call_id     UUID NOT NULL REFERENCES public.calls(id) ON DELETE CASCADE,
  user_id     UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  revealed    BOOLEAN NOT NULL DEFAULT false,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (call_id, user_id)
);

CREATE INDEX IF NOT EXISTS reveals_call_idx ON public.reveals(call_id);

ALTER TABLE public.reveals ENABLE ROW LEVEL SECURITY;

-- Read: a user sees every reveal row of a call they participated in —
-- that includes the peer's row, which is how the UI knows the peer's
-- decision.
DROP POLICY IF EXISTS "reveals_select_participant" ON public.reveals;
CREATE POLICY "reveals_select_participant"
  ON public.reveals FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.calls c
      WHERE c.id = reveals.call_id
        AND (c.caller_id = auth.uid() OR c.callee_id = auth.uid())
    )
  );

-- Write: a user creates / updates ONLY their own decision row, and only
-- for a call they actually took part in. The peer's row is untouchable.
DROP POLICY IF EXISTS "reveals_modify_own" ON public.reveals;
CREATE POLICY "reveals_modify_own"
  ON public.reveals FOR ALL
  USING (auth.uid() = user_id)
  WITH CHECK (
    auth.uid() = user_id
    AND EXISTS (
      SELECT 1 FROM public.calls c
      WHERE c.id = reveals.call_id
        AND (c.caller_id = auth.uid() OR c.callee_id = auth.uid())
    )
  );

-- Realtime so each client sees the peer's decision land live.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename = 'reveals'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.reveals;
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- matches — permanent match created when both peers reveal.
--
-- Self-contained CREATE (the table may be missing on a partially
-- migrated database). UNIQUE(user_a_id, user_b_id) + the ordered-pair
-- CHECK guarantee one match row per pair, so a double mutual-reveal
-- can't create duplicates.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.matches (
  id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_a_id            UUID NOT NULL
                         REFERENCES public.profiles(id) ON DELETE CASCADE,
  user_b_id            UUID NOT NULL
                         REFERENCES public.profiles(id) ON DELETE CASCADE,
  compatibility_score  SMALLINT NOT NULL
                         CHECK (compatibility_score BETWEEN 0 AND 100),
  matched_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
  status               TEXT NOT NULL DEFAULT 'new'
                         CHECK (status IN ('new', 'conversation_open', 'archived')),

  CONSTRAINT matches_no_self  CHECK (user_a_id <> user_b_id),
  CONSTRAINT matches_ordered  CHECK (user_a_id < user_b_id),
  UNIQUE (user_a_id, user_b_id)
);

ALTER TABLE public.matches
  ADD COLUMN IF NOT EXISTS call_id UUID
    REFERENCES public.calls(id) ON DELETE SET NULL;

ALTER TABLE public.matches ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "matches_all_participant" ON public.matches;
CREATE POLICY "matches_all_participant"
  ON public.matches FOR ALL
  USING (auth.uid() = user_a_id OR auth.uid() = user_b_id)
  WITH CHECK (auth.uid() = user_a_id OR auth.uid() = user_b_id);
