-- =============================================================================
-- DateNow — subscriptions + user_settings drift repair
--
-- A debug build on device showed the Home "Lancer un date" button doing
-- nothing at all, and the console said why two lines earlier:
--
--   [SupabaseSubscription][ERROR] subscription stream failed:
--     Could not find the table 'public.subscriptions' in the schema cache
--     (PGRST205)
--   [SupabaseAuth][WARN] ensure_profile_exists RPC failed (non-fatal):
--     relation "public.user_settings" does not exist (42P01)
--
-- Same partial-apply drift already documented for `reports`, `matches`,
-- `blocked_users` and the whole messaging pair: `subscriptions` (line 196)
-- and `user_settings` (line 211) are the LAST two tables of
-- 20260513120000_initial_schema.sql, and the remote stops at `reports`
-- (line 176). The migration is recorded as applied, so `db push` will
-- never go back for them.
--
-- What was broken by their absence, beyond the dead button:
--   * `quota_status()` reads `public.subscriptions` to decide the tier —
--     it therefore threw on every call, the client swallowed it as
--     "quota backend down, let the date through", and the 3-dates-a-day
--     cap was not enforced at all.
--   * `ensure_profile_exists()` and `handle_new_user()` both insert into
--     `user_settings`, so every signup logged a failure.
--   * The Settings screens had nowhere to persist to.
--
-- Guards match the original file (CREATE TABLE IF NOT EXISTS, DROP POLICY
-- IF EXISTS + CREATE, DO/EXCEPTION on the publication ALTER): a no-op on a
-- healthy remote, materialising on the drifted one.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- subscriptions
-- -----------------------------------------------------------------------------
-- One row per user. `stripe_subscription_id` stays unused while iOS billing
-- goes through StoreKit, but the tier column is what `quota_status()` reads.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.subscriptions (
  user_id                 UUID PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
  tier                    TEXT NOT NULL DEFAULT 'free'
                            CHECK (tier IN ('free', 'premium')),
  active_until            TIMESTAMPTZ,
  stripe_subscription_id  TEXT,
  updated_at              TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- -----------------------------------------------------------------------------
-- user_settings
-- -----------------------------------------------------------------------------
-- Account-level toggles surfaced under Settings → Notifications + Privacy
-- + Security. Mirrors NotificationPrefs + PrivacyPrefs in Dart.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.user_settings (
  user_id              UUID PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
  push_new_match       BOOLEAN NOT NULL DEFAULT true,
  push_suggestions     BOOLEAN NOT NULL DEFAULT true,
  push_messages        BOOLEAN NOT NULL DEFAULT true,
  email_weekly_digest  BOOLEAN NOT NULL DEFAULT true,
  email_marketing      BOOLEAN NOT NULL DEFAULT false,
  show_online          BOOLEAN NOT NULL DEFAULT true,
  block_screenshots    BOOLEAN NOT NULL DEFAULT true,
  share_usage_data     BOOLEAN NOT NULL DEFAULT true,
  marketing_consent    BOOLEAN NOT NULL DEFAULT false,
  two_factor_enabled   BOOLEAN NOT NULL DEFAULT false,
  updated_at           TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- -----------------------------------------------------------------------------
-- updated_at triggers
-- -----------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_subscriptions_updated_at ON public.subscriptions;
CREATE TRIGGER trg_subscriptions_updated_at
  BEFORE UPDATE ON public.subscriptions
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

DROP TRIGGER IF EXISTS trg_user_settings_updated_at ON public.user_settings;
CREATE TRIGGER trg_user_settings_updated_at
  BEFORE UPDATE ON public.user_settings
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- -----------------------------------------------------------------------------
-- RLS — owner-scoped, identical to 20260513120100_rls_policies.sql
-- -----------------------------------------------------------------------------
ALTER TABLE public.subscriptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_settings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "subscriptions_all_owner" ON public.subscriptions;
CREATE POLICY "subscriptions_all_owner"
  ON public.subscriptions FOR ALL
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "user_settings_all_owner" ON public.user_settings;
CREATE POLICY "user_settings_all_owner"
  ON public.user_settings FOR ALL
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

-- -----------------------------------------------------------------------------
-- Realtime — the client follows its own subscriptions row with
-- `.stream()`. Without the publication entry the channel errors and the
-- tier only ever arrives from the initial SELECT.
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename = 'subscriptions'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.subscriptions;
  END IF;
EXCEPTION
  WHEN undefined_object THEN
    RAISE NOTICE 'supabase_realtime publication missing — skipping';
END
$$;

-- -----------------------------------------------------------------------------
-- Backfill — every account that signed up while the tables were missing.
-- `handle_new_user` / `ensure_profile_exists` only cover new sessions;
-- these two statements settle the existing population in one pass.
-- -----------------------------------------------------------------------------
INSERT INTO public.subscriptions (user_id)
SELECT id FROM public.profiles
ON CONFLICT (user_id) DO NOTHING;

INSERT INTO public.user_settings (user_id)
SELECT id FROM public.profiles
ON CONFLICT (user_id) DO NOTHING;
