-- =============================================================================
-- DateNow — Discovery RLS relax
--
-- Two real users with compatible preferences could not see each other because
-- the original `profiles_select_suggested` policy required a row in
-- `weekly_suggestions` linking them — but populating that table requires
-- reading profiles in the first place (chicken-and-egg).
--
-- We open SELECT on basic profile + preference fields to any authenticated
-- user (excluding self). This is the privacy posture every major dating
-- product uses for the candidate-discovery surface: name + age + prefs are
-- visible to potential matches; **photos remain gated** by the unchanged
-- `user_photos_select_matched` policy.
--
-- Idempotent: every CREATE has a matching DROP IF EXISTS so this file can
-- be rerun against partially-migrated environments without conflict.
-- =============================================================================

-- Drop the chicken-and-egg policy if it exists (idempotent).
DROP POLICY IF EXISTS "profiles_select_suggested" ON public.profiles;

DROP POLICY IF EXISTS "profiles_select_for_discovery" ON public.profiles;
CREATE POLICY "profiles_select_for_discovery"
  ON public.profiles FOR SELECT
  USING (
    auth.uid() IS NOT NULL
    AND id <> auth.uid()
    AND first_name IS NOT NULL
    AND gender IS NOT NULL
  );

DROP POLICY IF EXISTS "user_prefs_select_for_discovery"
  ON public.user_preferences;
CREATE POLICY "user_prefs_select_for_discovery"
  ON public.user_preferences FOR SELECT
  USING (
    auth.uid() IS NOT NULL
    AND user_id <> auth.uid()
  );

-- Belt-and-braces policy that powers reads against historical
-- weekly_suggestions rows. Gated on the table actually existing so a
-- partial-migration environment (no weekly_suggestions yet) doesn't
-- block the critical discovery policies above.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'weekly_suggestions'
  ) THEN
    EXECUTE 'DROP POLICY IF EXISTS "profiles_select_via_suggestion" ON public.profiles';
    EXECUTE $POL$
      CREATE POLICY "profiles_select_via_suggestion"
        ON public.profiles FOR SELECT
        USING (
          EXISTS (
            SELECT 1 FROM public.weekly_suggestions s
            WHERE s.user_id = auth.uid()
              AND s.suggested_user_id = profiles.id
              AND s.status <> 'dismissed'
          )
        )
    $POL$;
  END IF;
END $$;
