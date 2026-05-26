-- =============================================================================
-- DateNow — per-user conversation hide
--
-- Lets a participant remove a conversation from their inbox *without*
-- destroying the row for the other side. Each (conversation_id, user_id)
-- pair tracks when that user chose to hide the thread; the inbox stream
-- joins against this table and skips rows where:
--   * the user has a deletion entry, AND
--   * the conversation has had no new activity since
--     (deletion.deleted_at < conversations.last_message_at)
-- That way a new message from the peer automatically resurfaces a
-- previously-hidden conversation (product spec).
--
-- Privacy:
--   * RLS scopes write+delete to the row's own user_id only — nobody can
--     hide a conversation they don't participate in.
--   * Read is also self-scoped (a user can only see their own hide rows).
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.conversation_deletions (
  conversation_id UUID NOT NULL
                    REFERENCES public.conversations(id) ON DELETE CASCADE,
  user_id         UUID NOT NULL
                    REFERENCES public.profiles(id) ON DELETE CASCADE,
  deleted_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (conversation_id, user_id)
);

CREATE INDEX IF NOT EXISTS conversation_deletions_user_idx
  ON public.conversation_deletions(user_id);

ALTER TABLE public.conversation_deletions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "conversation_deletions_self_select"
  ON public.conversation_deletions;
CREATE POLICY "conversation_deletions_self_select"
  ON public.conversation_deletions FOR SELECT
  USING (auth.uid() = user_id);

-- Insert + update + delete: only the same user, and only for a
-- conversation they actually participate in. Belt + suspenders.
DROP POLICY IF EXISTS "conversation_deletions_self_modify"
  ON public.conversation_deletions;
CREATE POLICY "conversation_deletions_self_modify"
  ON public.conversation_deletions FOR ALL
  USING (auth.uid() = user_id)
  WITH CHECK (
    auth.uid() = user_id
    AND EXISTS (
      SELECT 1 FROM public.conversations c
      WHERE c.id = conversation_deletions.conversation_id
        AND (c.user_a_id = auth.uid() OR c.user_b_id = auth.uid())
    )
  );

-- Realtime so the inbox stream picks up hides made on another device.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename = 'conversation_deletions'
  ) THEN
    ALTER PUBLICATION supabase_realtime
      ADD TABLE public.conversation_deletions;
  END IF;
END $$;
