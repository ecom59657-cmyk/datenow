-- -----------------------------------------------------------------------------
-- Repair: public.weekly_suggestions is missing from the deployed database
-- -----------------------------------------------------------------------------
-- The table has been in 20260513120000_initial_schema.sql since day one, but
-- PostgREST answers PGRST205 for it on the live project while every other
-- table of that migration answers normally. The repo has known about this for
-- months without naming it: 20260514120000 gates one of its policies on the
-- table existing, "so a partial-migration environment (no weekly_suggestions
-- yet) doesn't block the critical discovery policies", and
-- 20260514130000 carries the same caveat.
--
-- Consequence, until now invisible: Discover's weekly batch could never be
-- persisted, so it lived in RAM and reset on every app restart.
--
-- Everything here is idempotent and safe to run on a database that already
-- has the table — it is a no-op there.
-- -----------------------------------------------------------------------------

-- 1. The table, verbatim from the initial schema.
CREATE TABLE IF NOT EXISTS public.weekly_suggestions (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id               UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  suggested_user_id     UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  compatibility_score   SMALLINT NOT NULL
                          CHECK (compatibility_score BETWEEN 0 AND 100),
  week_start_date       DATE NOT NULL,
  status                TEXT NOT NULL DEFAULT 'pending'
                          CHECK (status IN (
                            'pending', 'dismissed', 'call_started', 'matched'
                          )),
  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),

  UNIQUE (user_id, suggested_user_id, week_start_date),
  CONSTRAINT suggestions_no_self CHECK (user_id <> suggested_user_id)
);

CREATE INDEX IF NOT EXISTS weekly_suggestions_user_week_idx
  ON public.weekly_suggestions(user_id, week_start_date);

-- 2. RLS. Without this the table would be readable by every authenticated
--    user, which is the opposite of what a suggestion list is.
ALTER TABLE public.weekly_suggestions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "suggestions_all_owner" ON public.weekly_suggestions;
CREATE POLICY "suggestions_all_owner"
  ON public.weekly_suggestions FOR ALL
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

-- 3. Re-apply the policy that 20260514120000 skipped.
--    That migration only creates `profiles_select_via_suggestion` when the
--    table exists — it did not, so the policy was never created. Without it
--    a user cannot read the profile of someone they were suggested, and the
--    Discover cards would come back empty even once the rows exist.
DROP POLICY IF EXISTS "profiles_select_via_suggestion" ON public.profiles;
CREATE POLICY "profiles_select_via_suggestion"
  ON public.profiles FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.weekly_suggestions s
      WHERE s.user_id = auth.uid()
        AND s.suggested_user_id = profiles.id
        AND s.status <> 'dismissed'
    )
  );

-- 4. Nudge PostgREST to reload its schema cache, otherwise the API keeps
--    answering PGRST205 until the next restart.
NOTIFY pgrst, 'reload schema';
