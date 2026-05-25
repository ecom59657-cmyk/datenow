-- =============================================================================
-- DateNow — push-notifications scaffolding (dormant until APNs keys set)
--
-- Adds:
--   * public.device_tokens — one row per (user_id, token). RLS so the
--     owner can manage their own tokens. The `message-notification`
--     Edge Function reads from this table with the service-role key.
--
-- Activation (manual, NOT done by this migration):
--   * APNs key (.p8) generated in Apple Developer Console.
--   * Push Notifications capability + Background Modes (Remote
--     notifications) added to the Runner target in Xcode.
--   * Supabase secrets set:
--       supabase secrets set \
--         APNS_KEY=$(cat AuthKey_XXXX.p8) \
--         APNS_KEY_ID=XXXX \
--         APNS_TEAM_ID=XXXX \
--         APNS_BUNDLE_ID=com.datenow.app
--   * Edge Function `message-notification` deployed:
--       supabase functions deploy message-notification
--   * Database webhook on INSERT into `public.messages` →
--     POST https://<project>.functions.supabase.co/message-notification
--
-- Until those are in place, this table simply sits empty and nothing
-- downstream fires — see docs/PUSH_NOTIFICATIONS_SETUP.md.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.device_tokens (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      UUID NOT NULL
                 REFERENCES public.profiles(id) ON DELETE CASCADE,
  platform     TEXT NOT NULL,
  token        TEXT NOT NULL,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT device_tokens_platform_check
    CHECK (platform IN ('ios', 'android')),
  UNIQUE (user_id, token)
);

CREATE INDEX IF NOT EXISTS device_tokens_user_idx
  ON public.device_tokens(user_id);

ALTER TABLE public.device_tokens ENABLE ROW LEVEL SECURITY;

-- Each user manages only their own tokens. The Edge Function reads via
-- service-role (which bypasses RLS), so the policy stays user-scoped.
DROP POLICY IF EXISTS "device_tokens_owner_all" ON public.device_tokens;
CREATE POLICY "device_tokens_owner_all"
  ON public.device_tokens FOR ALL
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);
