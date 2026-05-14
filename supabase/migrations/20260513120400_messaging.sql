-- =============================================================================
-- DateNow — messaging (only after a mutual post-call match)
--
-- Adds two tables:
--   - public.conversations
--   - public.messages
--
-- Plus RLS, a trigger that keeps `last_message_at` / `last_message_preview`
-- in sync on every insert, and the realtime publication entries so the
-- Flutter client's `.stream()` subscriptions fire on Postgres logical
-- replication events.
--
-- The product rule "no chat before a mutual match" is enforced by the
-- application: a `conversation` row is only inserted by `PostCallScreen`
-- when both peers chose "I want to match". The schema does not FK to
-- `matches` so it stays portable, but the canonical ordering constraint
-- (`user_a_id < user_b_id`) + UNIQUE pair prevents duplicates.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- conversations
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.conversations (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_a_id             UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  user_b_id             UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  last_message_at       TIMESTAMPTZ,
  last_message_preview  TEXT,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT conversations_no_self CHECK (user_a_id <> user_b_id),
  -- Canonical ordering so each pair has exactly one row.
  CONSTRAINT conversations_ordered CHECK (user_a_id < user_b_id),
  UNIQUE (user_a_id, user_b_id)
);

CREATE INDEX IF NOT EXISTS conversations_user_a_idx
  ON public.conversations(user_a_id);
CREATE INDEX IF NOT EXISTS conversations_user_b_idx
  ON public.conversations(user_b_id);

-- -----------------------------------------------------------------------------
-- messages
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.messages (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id  UUID NOT NULL REFERENCES public.conversations(id) ON DELETE CASCADE,
  sender_id        UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  body             TEXT NOT NULL CHECK (
                     length(trim(body)) > 0 AND length(body) <= 4000
                   ),
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  read_at          TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS messages_conversation_created_idx
  ON public.messages(conversation_id, created_at DESC);

-- -----------------------------------------------------------------------------
-- Trigger: keep conversations.last_message_at / last_message_preview fresh
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.update_conversation_on_message()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.conversations
  SET last_message_at = NEW.created_at,
      last_message_preview = left(NEW.body, 140)
  WHERE id = NEW.conversation_id;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_message_inserted ON public.messages;
CREATE TRIGGER on_message_inserted
  AFTER INSERT ON public.messages
  FOR EACH ROW
  EXECUTE FUNCTION public.update_conversation_on_message();

-- -----------------------------------------------------------------------------
-- RLS — conversations
-- -----------------------------------------------------------------------------
ALTER TABLE public.conversations ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "conversations_participant_select" ON public.conversations;
CREATE POLICY "conversations_participant_select"
  ON public.conversations FOR SELECT
  USING (auth.uid() IN (user_a_id, user_b_id));

DROP POLICY IF EXISTS "conversations_participant_insert" ON public.conversations;
CREATE POLICY "conversations_participant_insert"
  ON public.conversations FOR INSERT
  WITH CHECK (auth.uid() IN (user_a_id, user_b_id));

DROP POLICY IF EXISTS "conversations_participant_update" ON public.conversations;
CREATE POLICY "conversations_participant_update"
  ON public.conversations FOR UPDATE
  USING (auth.uid() IN (user_a_id, user_b_id))
  WITH CHECK (auth.uid() IN (user_a_id, user_b_id));

-- -----------------------------------------------------------------------------
-- RLS — messages
-- -----------------------------------------------------------------------------
ALTER TABLE public.messages ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "messages_participant_select" ON public.messages;
CREATE POLICY "messages_participant_select"
  ON public.messages FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.conversations c
      WHERE c.id = messages.conversation_id
        AND auth.uid() IN (c.user_a_id, c.user_b_id)
    )
  );

DROP POLICY IF EXISTS "messages_sender_insert" ON public.messages;
CREATE POLICY "messages_sender_insert"
  ON public.messages FOR INSERT
  WITH CHECK (
    sender_id = auth.uid()
    AND EXISTS (
      SELECT 1 FROM public.conversations c
      WHERE c.id = messages.conversation_id
        AND auth.uid() IN (c.user_a_id, c.user_b_id)
    )
  );

DROP POLICY IF EXISTS "messages_participant_update" ON public.messages;
CREATE POLICY "messages_participant_update"
  ON public.messages FOR UPDATE
  USING (
    EXISTS (
      SELECT 1 FROM public.conversations c
      WHERE c.id = messages.conversation_id
        AND auth.uid() IN (c.user_a_id, c.user_b_id)
    )
  );

-- -----------------------------------------------------------------------------
-- user_photos — extend SELECT to conversation participants
--
-- The existing matched-only policy from the initial schema migration won't
-- fire if we ever skip the matches table. This adds an OR branch so chat
-- participants can fetch each other's photos for the inbox / chat avatar.
-- -----------------------------------------------------------------------------
DROP POLICY IF EXISTS "user_photos_conversation_select" ON public.user_photos;
CREATE POLICY "user_photos_conversation_select"
  ON public.user_photos FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.conversations c
      WHERE (c.user_a_id = auth.uid() AND c.user_b_id = user_photos.user_id)
         OR (c.user_b_id = auth.uid() AND c.user_a_id = user_photos.user_id)
    )
  );

-- -----------------------------------------------------------------------------
-- Realtime — wire both tables into the supabase_realtime publication
-- so the Flutter SDK's `.stream()` receives logical-replication events.
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE public.messages;
EXCEPTION WHEN duplicate_object THEN
  -- already a member of the publication, nothing to do
END $$;

DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE public.conversations;
EXCEPTION WHEN duplicate_object THEN
  -- already a member of the publication, nothing to do
END $$;

ALTER TABLE public.messages REPLICA IDENTITY FULL;
ALTER TABLE public.conversations REPLICA IDENTITY FULL;
