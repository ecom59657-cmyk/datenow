-- -----------------------------------------------------------------------------
-- user_background — the five optional attributes collected at signup
-- -----------------------------------------------------------------------------
-- Origins, religion, drinking, smoking, education level.
--
-- Deliberately NOT columns on `profiles`. That table carries a broad read
-- policy (`profiles_select_for_discovery`) so the candidate pool can be scored
-- client-side, and origins and religion are special-category data under
-- article 9 of the GDPR — "Sensitive Info" in Apple's own privacy labels.
-- Putting them there would hand every signed-in account someone's religion for
-- no functional gain, since nothing scores on them today.
--
-- So this mirrors `user_prompts`: its own table, its own policy, readable by
-- any signed-in user except where a block exists in either direction.
--
-- Everything is nullable and an absent row is the normal state. Skipping the
-- step stores nothing at all rather than a "prefers not to say" marker — data
-- minimisation is the point, and a marker is still an answer.
--
-- Values are the Dart enum `.name`, i.e. camelCase, matching how
-- `sexual_orientation`, `intentions` and `interests` are already stored.
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.user_background (
  user_id     UUID PRIMARY KEY
                REFERENCES public.profiles(id) ON DELETE CASCADE,

  origins     TEXT[] NOT NULL DEFAULT '{}'
                CHECK (
                  origins <@ ARRAY[
                    'africa', 'northAfrica', 'eastAsia', 'southAsia',
                    'southeastAsia', 'caribbean', 'europe', 'latinAmerica',
                    'middleEast', 'nativeAmerican', 'pacific', 'other'
                  ]::TEXT[]
                ),

  religion    TEXT CHECK (
                religion IN (
                  'agnostic', 'atheist', 'buddhist', 'catholic', 'christian',
                  'hindu', 'jewish', 'muslim', 'sikh', 'spiritual', 'other'
                )
              ),

  drinking    TEXT CHECK (drinking IN ('never', 'socially', 'often')),

  smoking     TEXT CHECK (smoking IN ('never', 'occasionally', 'regularly')),

  education   TEXT CHECK (
                education IN (
                  'highSchool', 'vocational', 'bachelor', 'master',
                  'doctorate', 'other'
                )
              ),

  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Reuses the trigger function the other tables already use.
DROP TRIGGER IF EXISTS trg_user_background_updated_at ON public.user_background;
CREATE TRIGGER trg_user_background_updated_at
  BEFORE UPDATE ON public.user_background
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

ALTER TABLE public.user_background ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "user_background_modify_own" ON public.user_background;
CREATE POLICY "user_background_modify_own"
  ON public.user_background FOR ALL TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

-- Same shape as user_prompts_select_not_blocked: a block means the person
-- stops seeing what you wrote about yourself, in both directions.
DROP POLICY IF EXISTS "user_background_select_not_blocked"
  ON public.user_background;
CREATE POLICY "user_background_select_not_blocked"
  ON public.user_background FOR SELECT TO authenticated
  USING (
    auth.uid() IS NOT NULL
    AND NOT EXISTS (
      SELECT 1 FROM public.blocked_users b
      WHERE (b.user_id = auth.uid() AND b.blocked_user_id = user_background.user_id)
         OR (b.user_id = user_background.user_id AND b.blocked_user_id = auth.uid())
    )
  );

NOTIFY pgrst, 'reload schema';
