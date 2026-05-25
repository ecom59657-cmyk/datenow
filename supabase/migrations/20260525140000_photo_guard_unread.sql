-- =============================================================================
-- DateNow — photo guard before live + unread message count
--
--  * claim_match — refuses if either side has no photo (`user_photos` row
--    absent). The reveal makes no product sense otherwise: a successful
--    match would land both peers on a placeholder avatar instead of a
--    real face. Backed server-side so a tampered client cannot bypass
--    the new home-screen check.
--
--  * unread_messages_count() — total number of incoming messages with
--    `read_at IS NULL` across all of the caller's conversations.
--    Powers the badge on the Messages bottom-nav tab.
--
--  * mark_conversation_read(p_conversation_id) — flips read_at on every
--    INCOMING message of that conversation (sender_id <> me). Returns
--    the number of rows touched so the client can refresh the badge
--    without a round-trip.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. claim_match v4 — photo guard
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
  me_has_photo BOOLEAN;
  peer_has_photo BOOLEAN;
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

  -- Photo guard — neither side can match without at least one photo.
  -- The reveal is the product's payoff and only makes sense with a face.
  SELECT EXISTS (SELECT 1 FROM public.user_photos WHERE user_id = me)
    INTO me_has_photo;
  IF NOT me_has_photo THEN
    RAISE EXCEPTION 'photo_required';
  END IF;

  SELECT EXISTS (SELECT 1 FROM public.user_photos WHERE user_id = peer_id)
    INTO peer_has_photo;
  IF NOT peer_has_photo THEN
    RAISE EXCEPTION 'peer_unavailable';
  END IF;

  -- Already paired? Reuse the live session.
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

  -- Peer already on another live call?
  IF EXISTS (
    SELECT 1 FROM public.calls c
    WHERE (c.caller_id = peer_id OR c.callee_id = peer_id)
      AND c.status <> 'ended'
  ) THEN
    RAISE EXCEPTION 'peer_busy';
  END IF;

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

-- -----------------------------------------------------------------------------
-- 2. unread_messages_count() — drives the Messages tab badge
--
-- Only counts INCOMING messages (sender_id <> auth.uid()) with read_at
-- still NULL, scoped to conversations the caller participates in. RLS
-- on `messages` already restricts visibility; the join + auth.uid()
-- check is defence in depth so a SECURITY DEFINER doesn't accidentally
-- widen the surface.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.unread_messages_count()
RETURNS INTEGER
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT count(*)::int
  FROM public.messages m
  JOIN public.conversations c ON c.id = m.conversation_id
  WHERE m.read_at IS NULL
    AND m.sender_id <> auth.uid()
    AND auth.uid() IN (c.user_a_id, c.user_b_id);
$$;

GRANT EXECUTE ON FUNCTION public.unread_messages_count() TO authenticated;

-- -----------------------------------------------------------------------------
-- 3. mark_conversation_read(p_conversation_id)
--
-- Flips `read_at` on every incoming message of [p_conversation_id]
-- (sender <> caller). Returns how many rows were touched, so the
-- client can refresh the badge without re-querying. Refuses if the
-- caller is not a participant.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.mark_conversation_read(p_conversation_id UUID)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me      UUID := auth.uid();
  marked  INTEGER;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'unauthenticated';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.conversations c
    WHERE c.id = p_conversation_id
      AND me IN (c.user_a_id, c.user_b_id)
  ) THEN
    RAISE EXCEPTION 'not a participant';
  END IF;
  WITH upd AS (
    UPDATE public.messages
       SET read_at = now()
     WHERE conversation_id = p_conversation_id
       AND sender_id <> me
       AND read_at IS NULL
    RETURNING 1
  )
  SELECT count(*)::int INTO marked FROM upd;
  RETURN marked;
END;
$$;

GRANT EXECUTE ON FUNCTION public.mark_conversation_read(UUID) TO authenticated;
