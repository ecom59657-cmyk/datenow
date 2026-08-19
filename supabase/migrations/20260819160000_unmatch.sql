-- -----------------------------------------------------------------------------
-- unmatch(p_peer_id) — undo a mutual match without blocking the person
-- -----------------------------------------------------------------------------
-- Blocking and unmatching are different gestures. Blocking says "this person
-- must not reach me again" and writes to `blocked_users`; unmatching says
-- "this did not work out" and simply removes the pair. Until now only the
-- first existed, so anyone wanting to end a conversation had to escalate to
-- a block — or soft-delete their own copy and keep the match alive.
--
-- SECURITY DEFINER because the caller must be able to delete the peer's side
-- of the pair too: `matches_all_participant` and the conversations policy are
-- FOR ALL on rows the caller participates in, but relying on that from the
-- client would let a tampered request pick its own row ordering. The function
-- derives the canonical pair from auth.uid() instead, so the caller cannot
-- name a pair it is not part of.
--
-- Idempotent: deleting rows that are already gone is a no-op, so a double tap
-- (or a retry after a dropped connection) is harmless.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.unmatch(p_peer_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_self UUID := auth.uid();
  v_a    UUID := LEAST(auth.uid(), p_peer_id);
  v_b    UUID := GREATEST(auth.uid(), p_peer_id);
BEGIN
  IF v_self IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;
  IF v_self = p_peer_id THEN
    RAISE EXCEPTION 'cannot unmatch yourself';
  END IF;

  -- messages.conversation_id is ON DELETE CASCADE, so the thread goes with
  -- the conversation row.
  DELETE FROM public.conversations WHERE user_a_id = v_a AND user_b_id = v_b;
  DELETE FROM public.matches       WHERE user_a_id = v_a AND user_b_id = v_b;

  -- The suggestion that produced the pair is marked dismissed so the weekly
  -- batch never proposes them again. Guarded on the table existing: this
  -- function must not fail on a project where the initial schema has not been
  -- fully applied yet.
  IF to_regclass('public.weekly_suggestions') IS NOT NULL THEN
    UPDATE public.weekly_suggestions
       SET status = 'dismissed'
     WHERE (user_id = v_self AND suggested_user_id = p_peer_id)
        OR (user_id = p_peer_id AND suggested_user_id = v_self);
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.unmatch(UUID) TO authenticated;
