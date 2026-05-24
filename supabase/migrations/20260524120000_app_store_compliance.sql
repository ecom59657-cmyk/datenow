-- =============================================================================
-- DateNow — App Store / TestFlight compliance hardening
--
-- Adds the minimum server-side surface Apple expects from a dating app
-- with live video:
--   * profiles.is_banned + moderation_status + banned_reason
--   * reports.reason CHECK constraint (enum-style)
--   * block_user(p_user_id) — SECURITY DEFINER one-shot block
--   * delete_my_account() — wipes the caller's data; the matching
--     Edge Function (`delete-account`) deletes the auth.users row with
--     service_role afterwards.
--   * claim_match — extended to refuse matches involving a banned user
--     so the bypassable client check is backed by a hard server gate.
--
-- Idempotent: every statement uses IF NOT EXISTS / DO blocks / CREATE OR
-- REPLACE so re-running on an already-migrated DB is a no-op.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Moderation columns on profiles
-- -----------------------------------------------------------------------------
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS is_banned          BOOLEAN NOT NULL DEFAULT false;

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS banned_reason      TEXT;

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS moderation_status  TEXT NOT NULL DEFAULT 'active';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'profiles_moderation_status_check'
      AND conrelid = 'public.profiles'::regclass
  ) THEN
    ALTER TABLE public.profiles
      ADD CONSTRAINT profiles_moderation_status_check
      CHECK (moderation_status IN ('active', 'suspended', 'banned'));
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS profiles_is_banned_idx
  ON public.profiles(is_banned) WHERE is_banned = true;

-- -----------------------------------------------------------------------------
-- 2. Reports — self-contained re-create (defensive) + reason CHECK
--
-- The `reports` table is in the initial schema, but at least one remote
-- has the initial migration marked as applied without the table actually
-- present (file was extended after first apply). Mirror what
-- `20260517130000_reveals.sql` does for `matches`: recreate everything
-- under IF NOT EXISTS so this migration succeeds whether the table is
-- there or not.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.reports (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  reporter_id       UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
  reported_user_id  UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  reason            TEXT NOT NULL,
  details           TEXT,
  status            TEXT NOT NULL DEFAULT 'pending'
                      CHECK (status IN ('pending', 'reviewed', 'dismissed')),
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS reports_status_idx ON public.reports(status);

ALTER TABLE public.reports ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'reports_reason_check'
      AND conrelid = 'public.reports'::regclass
  ) THEN
    ALTER TABLE public.reports
      ADD CONSTRAINT reports_reason_check
      CHECK (reason IN (
        'inappropriate_behavior',
        'nudity_sexual',
        'harassment',
        'minor',
        'fake_profile',
        'spam',
        'other'
      ));
  END IF;
END $$;

-- Re-create policies so the table is usable end-to-end even if the
-- initial RLS migration was applied before the table existed.
DROP POLICY IF EXISTS "reports_select_self" ON public.reports;
CREATE POLICY "reports_select_self"
  ON public.reports FOR SELECT
  USING (auth.uid() = reporter_id);

DROP POLICY IF EXISTS "reports_insert_self" ON public.reports;
CREATE POLICY "reports_insert_self"
  ON public.reports FOR INSERT
  WITH CHECK (
    auth.uid() = reporter_id
    AND reported_user_id <> auth.uid()
  );

-- -----------------------------------------------------------------------------
-- 3. block_user(p_user_id) — atomic block helper
--
-- A SECURITY DEFINER RPC so the client always inserts a clean row and we
-- can extend the block side-effects (cancel an active call, end any chat)
-- later without changing the client surface.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.block_user(p_user_id UUID)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me UUID := auth.uid();
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'unauthenticated';
  END IF;
  IF me = p_user_id THEN
    RAISE EXCEPTION 'cannot_block_self';
  END IF;

  INSERT INTO public.blocked_users (user_id, blocked_user_id)
  VALUES (me, p_user_id)
  ON CONFLICT (user_id, blocked_user_id) DO NOTHING;

  -- Force-end any live call between the two so the blocker isn't kept
  -- on the line with the blocked peer.
  UPDATE public.calls
  SET status = 'ended', ended_at = now(), ended_by = me
  WHERE status <> 'ended'
    AND ((caller_id = me AND callee_id = p_user_id)
      OR (caller_id = p_user_id AND callee_id = me));
END;
$$;

GRANT EXECUTE ON FUNCTION public.block_user(UUID) TO authenticated;

-- -----------------------------------------------------------------------------
-- 4. delete_my_account() — wipes caller's data
--
-- The companion Edge Function `delete-account` calls this RPC (as the
-- user, via RLS) then deletes the auth.users row with service_role.
-- That two-step keeps audit-friendly per-table deletes via cascade while
-- the privileged auth deletion stays out of the client.
--
-- ON DELETE CASCADE on profiles.id (FK → auth.users) wipes downstream:
--   user_preferences, user_photos, weekly_suggestions, matches, calls,
--   blocked_users, conversations + messages, reveals, subscriptions,
--   user_settings, user_presence, matchmaking_queue.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.delete_my_account()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me UUID := auth.uid();
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'unauthenticated';
  END IF;

  -- Pull self out of live surfaces first so a peer mid-search doesn't
  -- end up paired with a half-deleted account.
  DELETE FROM public.matchmaking_queue WHERE user_id = me;
  DELETE FROM public.user_presence     WHERE user_id = me;

  UPDATE public.calls
  SET status = 'ended', ended_at = now(), ended_by = me
  WHERE (caller_id = me OR callee_id = me)
    AND status <> 'ended';

  -- Cascade fans out to every dependent table.
  DELETE FROM public.profiles WHERE id = me;
END;
$$;

GRANT EXECUTE ON FUNCTION public.delete_my_account() TO authenticated;

-- -----------------------------------------------------------------------------
-- 5. claim_match — refuse matches involving a banned account
--
-- The previous version already validated authentication + no self-match
-- + atomic single-call-per-pair. We extend it with a server-side ban
-- gate so a manipulated client can't bypass moderation.
-- Returns same JSONB shape as before (the calls row).
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
