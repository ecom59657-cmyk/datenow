-- =============================================================================
-- DateNow — user_photos moderation defense-in-depth
--
-- Build 35 TestFlight revealed that a client could in principle bypass
-- the moderation pipeline by INSERTing a `user_photos` row with
-- `status='approved'` directly (the existing `user_photos_all_owner`
-- RLS policy lets the user write any column of their own row, including
-- `status` and the other moderation metadata).
--
-- This migration adds two BEFORE triggers that close the loophole at
-- the database level — independent of any Flutter code, so a tampered
-- or compromised client can never short-circuit the verdict.
--
--   1. user_photos_force_pending  (BEFORE INSERT)
--      Every new row is forced to {status='pending', moderation_*=NULL}
--      regardless of what the client tried to set.
--
--   2. user_photos_lock_moderation (BEFORE UPDATE)
--      An authenticated user (role 'authenticated' / 'anon') cannot
--      change `status`, `moderation_provider`, `moderation_score`,
--      `moderation_at` or `reject_reason`. Only the service role used
--      by `analyze-profile-photo` and by Supabase Studio (admin review)
--      may write these columns.
--
-- After this migration the invariant the brief asked for is enforced
-- at the schema level:
--
--   "Aucun nouvel upload ne peut être approved avant analyse"
--   "Seul analyze-profile-photo ou un admin peut passer
--    approved / rejected / manual_review"
-- =============================================================================

-- ── 1. BEFORE INSERT : force pending on every new row ──────────
CREATE OR REPLACE FUNCTION public.user_photos_force_pending_on_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  -- Reset every moderation column to its initial state. The Edge
  -- Function `analyze-profile-photo` will UPDATE these via the
  -- service role once Google Vision has decided.
  NEW.status              := 'pending';
  NEW.moderation_provider := NULL;
  NEW.moderation_score    := NULL;
  NEW.moderation_at       := NULL;
  NEW.reject_reason       := NULL;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS user_photos_force_pending ON public.user_photos;
CREATE TRIGGER user_photos_force_pending
  BEFORE INSERT ON public.user_photos
  FOR EACH ROW
  EXECUTE FUNCTION public.user_photos_force_pending_on_insert();

-- ── 2. BEFORE UPDATE : lock moderation fields for non-admins ───
CREATE OR REPLACE FUNCTION public.user_photos_lock_moderation_fields()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  -- Service-role updates (Edge Function + Supabase Studio admin
  -- review) bypass the lock — those are the ONLY paths that may
  -- change moderation columns. Plain `postgres` superuser also
  -- bypasses for migrations / data fixes.
  IF current_user IN ('service_role', 'postgres', 'supabase_admin') THEN
    RETURN NEW;
  END IF;

  -- An authenticated user can still update their non-moderation
  -- columns (position, is_primary, …) on their own row — RLS still
  -- gates ownership. We only refuse changes to the moderation
  -- contract.
  IF NEW.status              IS DISTINCT FROM OLD.status
     OR NEW.moderation_provider IS DISTINCT FROM OLD.moderation_provider
     OR NEW.moderation_score    IS DISTINCT FROM OLD.moderation_score
     OR NEW.moderation_at       IS DISTINCT FROM OLD.moderation_at
     OR NEW.reject_reason       IS DISTINCT FROM OLD.reject_reason
  THEN
    RAISE EXCEPTION
      'user_photos moderation fields are read-only for role %, '
      'only analyze-profile-photo (service_role) or admin may write them',
      current_user
      USING ERRCODE = '42501'; -- insufficient_privilege
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS user_photos_lock_moderation ON public.user_photos;
CREATE TRIGGER user_photos_lock_moderation
  BEFORE UPDATE ON public.user_photos
  FOR EACH ROW
  EXECUTE FUNCTION public.user_photos_lock_moderation_fields();
