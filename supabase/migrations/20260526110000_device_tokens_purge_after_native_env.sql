-- =============================================================================
-- DateNow — purge device_tokens after switching to native aps-environment
--
-- Previous Flutter code (kReleaseMode-based) wrote 'production' for
-- debug builds whose actual entitlement was 'development', producing
-- BadEnvironmentKeyInToken on every push. The Flutter client now reads
-- the real `aps-environment` from the iOS bridge (parses
-- embedded.mobileprovision), so existing rows are unreliable and must
-- be re-registered. Clients re-upsert on next app open via the
-- onTokenRefresh / requestPermissionAndRegister flow.
-- =============================================================================

TRUNCATE TABLE public.device_tokens;
