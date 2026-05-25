-- =============================================================================
-- DateNow — clean device_tokens before APNs auto-heal rollout
--
-- The Edge Function now auto-corrects rows whose apns_environment is
-- wrong (retries on the opposite host, then UPDATEs the row on success).
-- Before that goes live we wipe the table so the next round of registrations
-- starts from a known-good state — the iOS clients re-upsert
-- automatically on next launch thanks to PushNotificationsService
-- .maybeRegisterForSignedInUser, called on every sign-in / token-refresh
-- event.
-- =============================================================================

TRUNCATE TABLE public.device_tokens;
