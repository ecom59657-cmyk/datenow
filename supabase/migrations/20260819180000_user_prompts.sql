-- -----------------------------------------------------------------------------
-- user_prompts — the first user-written text in the app
-- -----------------------------------------------------------------------------
-- Short answers to a closed bank of questions. A free-text bio would produce
-- empty paragraphs and a moderation load this team cannot carry; a precise
-- question produces a concrete opening for a five-minute video date.
--
-- `question` stores the Dart enum name verbatim (`PromptQuestion.name`). The
-- CHECK below is the other half of that contract: adding a value on one side
-- only means the insert is rejected at runtime.
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.user_prompts (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  question    TEXT NOT NULL CHECK (question IN (
                'perfectSunday', 'cantShutUpAbout', 'makeMeLaugh',
                'learningRightNow', 'unpopularOpinion', 'bestMealEver',
                'weekendPlan', 'proudOf', 'neverAgain', 'firstThingNotice',
                'simplePleasure', 'wouldTravelTo', 'badAt', 'changedMyMind',
                'soundtrack', 'askMeAbout'
              )),
  -- 140 characters, enforced here and not only in the UI: the limit is what
  -- keeps these openers rather than biographies, and a tampered client must
  -- not be able to store a paragraph.
  answer      TEXT NOT NULL CHECK (
                length(trim(answer)) > 0 AND length(answer) <= 140
              ),
  position    SMALLINT NOT NULL DEFAULT 0 CHECK (position BETWEEN 0 AND 2),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),

  -- One answer per question per person, and at most three rows (position
  -- 0..2) — the ceiling is structural, not a UI convention.
  UNIQUE (user_id, question),
  UNIQUE (user_id, position)
);

CREATE INDEX IF NOT EXISTS user_prompts_user_idx
  ON public.user_prompts(user_id, position);

DROP TRIGGER IF EXISTS trg_user_prompts_updated_at ON public.user_prompts;
CREATE TRIGGER trg_user_prompts_updated_at
  BEFORE UPDATE ON public.user_prompts
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

ALTER TABLE public.user_prompts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "user_prompts_modify_own" ON public.user_prompts;
CREATE POLICY "user_prompts_modify_own"
  ON public.user_prompts FOR ALL TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

-- Read access is deliberately narrower than the plan's `USING (true)`.
--
-- The rest of the profile is already broadly readable (cf.
-- `profiles_select_for_discovery`), and the pool has to be scoreable
-- client-side, so prompts follow the same shape — but with one difference
-- that matters: this is the only table holding text a human wrote. Leaving it
-- open to every authenticated account means a blocked person keeps reading
-- what you wrote, which is not what "bloquer" means to the person who tapped
-- it, and it hands a scraper a clean corpus.
--
-- So: any signed-in user except where a block exists in either direction.
DROP POLICY IF EXISTS "user_prompts_select_authenticated" ON public.user_prompts;
DROP POLICY IF EXISTS "user_prompts_select_not_blocked" ON public.user_prompts;
CREATE POLICY "user_prompts_select_not_blocked"
  ON public.user_prompts FOR SELECT TO authenticated
  USING (
    auth.uid() IS NOT NULL
    AND NOT EXISTS (
      SELECT 1 FROM public.blocked_users b
      WHERE (b.user_id = auth.uid() AND b.blocked_user_id = user_prompts.user_id)
         OR (b.user_id = user_prompts.user_id AND b.blocked_user_id = auth.uid())
    )
  );

NOTIFY pgrst, 'reload schema';
