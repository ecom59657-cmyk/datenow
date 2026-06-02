-- =============================================================================
-- DateNow — GDPR Sprint, Commit 2 :
--           Add FK + ON DELETE CASCADE to moderation_audit_log
--
-- Closes GDPR audit blocker §6c.
--
-- Until this migration the `moderation_audit_log` table (introduced
-- in 20260531120000_photo_moderation_schema.sql) had two bare UUID
-- columns — `photo_id` and `user_id` — with NO FOREIGN KEY. The
-- consequence was that every row outlived its owner indefinitely :
-- deleting a user via delete_my_account() removed their profiles
-- row + the cascaded user_photos rows, but the audit log kept
-- referencing those dead UUIDs forever. The orphan rows carry
-- biometric processing data (Google Vision face bounding boxes
-- in `payload`), which makes the retention a direct Article 17
-- right-to-erasure breach.
--
-- This migration :
--   1. Removes any pre-existing orphan rows (the rows that no longer
--      have a matching user_photos / profiles parent) so the FK
--      constraint will accept the existing data when it is added.
--   2. Adds two FOREIGN KEY constraints with ON DELETE CASCADE so
--      future deletes are cleaned up automatically.
--
-- Migration safety :
--   - Idempotent : the DO blocks check `pg_constraint` before adding,
--     and the cleanup DELETEs run against rows that no longer have a
--     parent (no risk of cascading to live data, since by definition
--     the parent does not exist).
--   - Backward compatible : reads of moderation_audit_log carry on
--     working ; only the orphan rows are removed (which the GDPR
--     audit explicitly flagged as the violation we want to fix).
--   - Rollback : the inverse migration drops both constraints
--     (`ALTER TABLE … DROP CONSTRAINT … IF EXISTS`).
-- =============================================================================

-- ── 1. Defensive cleanup of pre-existing orphan rows ────────────
-- Two DELETEs : one per parent. Both are bounded by `NOT EXISTS`
-- so they touch only rows that already lost their parent.
--
-- This is a one-shot effect of adding the FK constraint. Once the
-- FK is in place every future delete propagates automatically.
DELETE FROM public.moderation_audit_log
 WHERE NOT EXISTS (
   SELECT 1 FROM public.user_photos
    WHERE user_photos.id = moderation_audit_log.photo_id
 );

DELETE FROM public.moderation_audit_log
 WHERE NOT EXISTS (
   SELECT 1 FROM public.profiles
    WHERE profiles.id = moderation_audit_log.user_id
 );

-- ── 2. Add FK constraints (idempotent) ─────────────────────────
-- photo_id → user_photos(id) ON DELETE CASCADE
-- user_id  → profiles(id)    ON DELETE CASCADE
--
-- We wrap the two ALTER TABLE statements in `DO $$ … $$` blocks
-- so this migration can be re-applied on a partially-migrated DB
-- (e.g. a previous attempt that completed step 1 but not step 2).
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conname = 'moderation_audit_log_photo_id_fkey'
       AND conrelid = 'public.moderation_audit_log'::regclass
  ) THEN
    ALTER TABLE public.moderation_audit_log
      ADD CONSTRAINT moderation_audit_log_photo_id_fkey
        FOREIGN KEY (photo_id)
        REFERENCES public.user_photos(id)
        ON DELETE CASCADE;
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conname = 'moderation_audit_log_user_id_fkey'
       AND conrelid = 'public.moderation_audit_log'::regclass
  ) THEN
    ALTER TABLE public.moderation_audit_log
      ADD CONSTRAINT moderation_audit_log_user_id_fkey
        FOREIGN KEY (user_id)
        REFERENCES public.profiles(id)
        ON DELETE CASCADE;
  END IF;
END $$;

COMMENT ON CONSTRAINT moderation_audit_log_photo_id_fkey
  ON public.moderation_audit_log IS
  'GDPR sprint commit 2: CASCADE delete on photo removal '
  'prevents orphan audit rows carrying biometric Vision data.';

COMMENT ON CONSTRAINT moderation_audit_log_user_id_fkey
  ON public.moderation_audit_log IS
  'GDPR sprint commit 2: CASCADE delete on user erasure prevents '
  'orphan audit rows carrying biometric Vision data after Article 17.';

-- =============================================================================
-- After this migration applies :
--
--   - Existing orphan rows in moderation_audit_log are removed
--     (Article 17 erasure of past dead-user data).
--   - Future user deletes (via delete_my_account() + Storage wipe
--     from GDPR sprint commit 1) propagate to moderation_audit_log
--     automatically, leaving no biometric residue.
--   - The DB CASCADE chain from auth.users -> profiles -> user_photos
--     -> moderation_audit_log is now complete.
-- =============================================================================
