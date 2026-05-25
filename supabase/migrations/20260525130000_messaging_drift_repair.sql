-- =============================================================================
-- DateNow — messaging drift repair
--
-- TestFlight build surfaced `PostgrestException: Could not find the table
-- 'public.conversations' in the schema cache (code PGRST205)` on the
-- Messages tab. `supabase migration list --linked` shows
-- 20260513120400_messaging.sql under BOTH Local and Remote, but the
-- conversations / messages tables are missing on this project — same
-- partial-apply drift we already documented for `reports`, `matches`,
-- `blocked_users` (initial migration file extended after first apply,
-- so the second half of its DDL never ran on the remote).
--
-- This migration RE-RUNS the entire messaging DDL with the same
-- guards the original file uses (CREATE TABLE IF NOT EXISTS, DROP POLICY
-- IF EXISTS + CREATE POLICY, DO/EXCEPTION on the publication ALTER).
-- On a healthy remote this is a no-op. On the drifted one it materialises
-- the missing tables, RLS, trigger and realtime publication entries.
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
-- user_photos — extend SELECT to conversation participants (idempotent)
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
-- Realtime publication (idempotent via DO/EXCEPTION)
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE public.messages;
EXCEPTION WHEN duplicate_object THEN
  -- already a member, nothing to do
END $$;

DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE public.conversations;
EXCEPTION WHEN duplicate_object THEN
  -- already a member, nothing to do
END $$;

ALTER TABLE public.messages REPLICA IDENTITY FULL;
ALTER TABLE public.conversations REPLICA IDENTITY FULL;
