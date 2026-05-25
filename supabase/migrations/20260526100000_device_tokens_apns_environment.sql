-- =============================================================================
-- DateNow — device_tokens.apns_environment
--
-- Fixes the `BadEnvironmentKeyInToken` errors from APNs: a device token
-- is environment-bound (sandbox vs production), and our backend was
-- routing every push to a single host (api.push.apple.com), causing
-- sandbox tokens (Debug builds, Xcode Run) to fail in prod and prod
-- tokens (TestFlight, App Store) to fail in sandbox.
--
-- Each token now carries the environment of the build that produced it:
--   * 'development' — Debug builds installed by Xcode (sandbox APNs)
--   * 'production'  — TestFlight + App Store builds (prod APNs)
--
-- The Edge Function picks the host per token at send time.
--
-- ── Backward-compat note ──────────────────────────────────────────────
-- Pre-existing rows have no env. We default them to 'production' (true
-- for any TestFlight build), THEN truncate the table — the few tokens
-- registered during diagnostics must be re-registered with the new
-- column populated so we know which environment they belong to. The
-- Flutter client re-upserts automatically on next app open.
-- =============================================================================

ALTER TABLE public.device_tokens
  ADD COLUMN IF NOT EXISTS apns_environment TEXT NOT NULL DEFAULT 'production';

ALTER TABLE public.device_tokens
  DROP CONSTRAINT IF EXISTS device_tokens_apns_environment_check;
ALTER TABLE public.device_tokens
  ADD CONSTRAINT device_tokens_apns_environment_check
  CHECK (apns_environment IN ('development', 'production'));

CREATE INDEX IF NOT EXISTS device_tokens_user_platform_env_idx
  ON public.device_tokens(user_id, platform, apns_environment);

-- Purge rows that pre-date the column — their environment is unknown
-- (probably development on a debug-build device the team installed via
-- Xcode). The clients re-register on next launch with the correct env.
TRUNCATE TABLE public.device_tokens;
