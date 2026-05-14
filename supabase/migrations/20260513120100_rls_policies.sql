-- =============================================================================
-- DateNow — Row Level Security
--
-- Default-deny on every table. Each policy below grants the minimum access
-- a feature needs. When in doubt, prefer narrower (per-statement, per-role)
-- policies over wide ones.
--
-- Convention: policy names follow `<table>_<verb>_<scope>` so the intent
-- is readable in psql's `\d+` output.
-- =============================================================================

ALTER TABLE public.profiles            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_preferences    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_photos         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.weekly_suggestions  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.matches             ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.calls               ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.blocked_users       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reports             ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.subscriptions       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_settings       ENABLE ROW LEVEL SECURITY;

-- -----------------------------------------------------------------------------
-- profiles
-- -----------------------------------------------------------------------------
-- Each user can see + edit their own row. Matched users can see each
-- other's basic info. Suggested users can see each other's basic info too,
-- which is what powers the Discover cards (no photos here — that policy
-- lives on `user_photos`).
-- INSERT is reserved to the auth trigger (SECURITY DEFINER, bypasses RLS).
-- -----------------------------------------------------------------------------
CREATE POLICY "profiles_select_self"
  ON public.profiles FOR SELECT
  USING (auth.uid() = id);

CREATE POLICY "profiles_select_matched"
  ON public.profiles FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.matches m
      WHERE (m.user_a_id = auth.uid() AND m.user_b_id = profiles.id)
         OR (m.user_b_id = auth.uid() AND m.user_a_id = profiles.id)
    )
  );

CREATE POLICY "profiles_select_suggested"
  ON public.profiles FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.weekly_suggestions s
      WHERE s.user_id = auth.uid()
        AND s.suggested_user_id = profiles.id
        AND s.status <> 'dismissed'
    )
  );

CREATE POLICY "profiles_update_self"
  ON public.profiles FOR UPDATE
  USING (auth.uid() = id)
  WITH CHECK (auth.uid() = id);

-- -----------------------------------------------------------------------------
-- user_preferences — fully owner-scoped
-- -----------------------------------------------------------------------------
CREATE POLICY "user_prefs_all_owner"
  ON public.user_preferences FOR ALL
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

-- -----------------------------------------------------------------------------
-- user_photos — owner CRUD + matched users may SELECT
--
-- This is the product rule "photos stay private until a 5-minute date
-- completes". Non-matched users cannot read the metadata; the storage RLS
-- in 20260513120300_storage.sql blocks access to the bytes themselves.
-- -----------------------------------------------------------------------------
CREATE POLICY "user_photos_all_owner"
  ON public.user_photos FOR ALL
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "user_photos_select_matched"
  ON public.user_photos FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.matches m
      WHERE (m.user_a_id = auth.uid() AND m.user_b_id = user_photos.user_id)
         OR (m.user_b_id = auth.uid() AND m.user_a_id = user_photos.user_id)
    )
  );

-- -----------------------------------------------------------------------------
-- weekly_suggestions — owner-scoped (the recipient sees their own batch)
-- -----------------------------------------------------------------------------
CREATE POLICY "suggestions_all_owner"
  ON public.weekly_suggestions FOR ALL
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

-- -----------------------------------------------------------------------------
-- matches — visible + updatable by either participant
-- -----------------------------------------------------------------------------
CREATE POLICY "matches_all_participant"
  ON public.matches FOR ALL
  USING (auth.uid() = user_a_id OR auth.uid() = user_b_id)
  WITH CHECK (auth.uid() = user_a_id OR auth.uid() = user_b_id);

-- -----------------------------------------------------------------------------
-- calls — visible + updatable by caller / callee
-- -----------------------------------------------------------------------------
CREATE POLICY "calls_all_participant"
  ON public.calls FOR ALL
  USING (auth.uid() = caller_id OR auth.uid() = callee_id)
  WITH CHECK (auth.uid() = caller_id OR auth.uid() = callee_id);

-- -----------------------------------------------------------------------------
-- blocked_users — only the blocker reads / manages their own block list
-- -----------------------------------------------------------------------------
CREATE POLICY "blocked_users_all_owner"
  ON public.blocked_users FOR ALL
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

-- -----------------------------------------------------------------------------
-- reports — only the reporter sees their own submissions
-- -----------------------------------------------------------------------------
CREATE POLICY "reports_insert_self"
  ON public.reports FOR INSERT
  WITH CHECK (auth.uid() = reporter_id);

CREATE POLICY "reports_select_self"
  ON public.reports FOR SELECT
  USING (auth.uid() = reporter_id);

-- -----------------------------------------------------------------------------
-- subscriptions + user_settings — owner-scoped
-- -----------------------------------------------------------------------------
CREATE POLICY "subscriptions_all_owner"
  ON public.subscriptions FOR ALL
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "user_settings_all_owner"
  ON public.user_settings FOR ALL
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);
