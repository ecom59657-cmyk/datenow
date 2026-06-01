-- =============================================================================
-- DateNow — profiles.timezone (Phase A of the timezone refactor)
--
-- Adds the IANA timezone column that will become the SINGLE source of
-- truth for every server-side time-aware decision in DateNow :
--   - push notification quiet hours (Phase C)
--   - daily reminder / digest scheduling (Phase C)
--   - weekly suggestion reset (future)
--   - matching availability windows ("ce soir", "demain matin", …)
--
-- This migration is intentionally MINIMAL. It only :
--   1. adds the nullable column profiles.timezone TEXT,
--   2. installs the validation trigger that rejects non-IANA values,
--   3. ships the RPC update_my_timezone(tz) the Flutter bootstrap
--      (Phase B) will call from cold-start to populate it.
--
-- Out of scope for this commit :
--   - the Flutter bootstrap itself (flutter_timezone plugin),
--   - the push-notification quiet-hours logic (Phase C — strategy is
--     to QUEUE/DEFER until 8h local, never to skip outright per
--     product spec amendment 2026-06-01),
--   - any retroactive backfill — existing rows stay NULL until each
--     user's next cold start, and the server fallback is UTC.
--
-- Migration safety :
--   - NEW column is nullable with no default, no backfill — zero
--     impact on existing rows or builds <= 0.1.0+37.
--   - RLS untouched. The new column inherits the existing
--     `profiles_select_own` policy for reads. Writes go through the
--     SECURITY DEFINER RPC (preferred) or a direct UPDATE on the
--     row's own id (validated by the trigger below).
--   - Identity-lock trigger (profiles_lock_identity, Phase 1 Didit)
--     untouched — it only guards identity_* columns, not timezone.
-- =============================================================================

-- ── 1. Column ────────────────────────────────────────────────────
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS timezone TEXT;

COMMENT ON COLUMN public.profiles.timezone IS
  'IANA timezone name (e.g. Europe/Paris, America/New_York, UTC). '
  'Single source of truth for every server-side time-aware decision : '
  'push quiet hours, daily reminders, weekly suggestion reset. '
  'NULL is treated as UTC by all server-side consumers. Populated '
  'by the update_my_timezone() RPC at every Flutter cold start '
  '(Phase B). The DB never stores local timestamps - all TIMESTAMPTZ '
  'columns remain UTC, the timezone column is only consulted server-'
  'side to derive a local hour from a UTC timestamp.';

-- ── 2. Validation trigger ────────────────────────────────────────
-- Defense in depth : even if the Flutter client bypasses the RPC
-- and tries a direct PostgREST UPDATE on profiles.timezone, this
-- trigger rejects any non-IANA value at the DB level. Validates
-- against pg_timezone_names which is the canonical IANA db
-- Postgres bundles.
--
-- Only fires on UPDATE (column doesn't exist on existing INSERT
-- code paths and a NULL initial value is allowed). Short-circuits
-- when the new value is NULL or unchanged from the old, so a
-- normal saveProfile that touches first_name / birth_date / etc.
-- passes through with zero overhead.
CREATE OR REPLACE FUNCTION public.profiles_validate_timezone()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.timezone IS NOT NULL
     AND NEW.timezone IS DISTINCT FROM OLD.timezone
  THEN
    IF NOT EXISTS (
      SELECT 1 FROM pg_timezone_names WHERE name = NEW.timezone
    ) THEN
      RAISE EXCEPTION 'Invalid IANA timezone: %', NEW.timezone
        USING ERRCODE = '22023';  -- invalid_parameter_value
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS profiles_validate_timezone ON public.profiles;
CREATE TRIGGER profiles_validate_timezone
  BEFORE UPDATE ON public.profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.profiles_validate_timezone();

-- ── 3. RPC update_my_timezone ────────────────────────────────────
-- Single supported path for the Flutter client to record the
-- user's IANA timezone after the cold-start bootstrap (Phase B
-- will call this). SECURITY DEFINER + scoped to auth.uid() so a
-- tampered client cannot write to anyone else's row.
--
-- Raises :
--   * 22023 (invalid_parameter_value) on null or non-IANA input,
--   * 42501 (insufficient_privilege) when auth.uid() is null.
CREATE OR REPLACE FUNCTION public.update_my_timezone(tz TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = '42501';
  END IF;
  IF tz IS NULL THEN
    RAISE EXCEPTION 'timezone cannot be NULL'
      USING ERRCODE = '22023';
  END IF;
  -- pg_timezone_names is the IANA db Postgres ships with.
  -- Accepts canonical names ("Europe/Paris") plus historical
  -- aliases ("US/Eastern", "GMT", …). The Flutter plugin
  -- flutter_timezone emits canonical names, so this is mostly
  -- a defense against tampered clients.
  IF NOT EXISTS (
    SELECT 1 FROM pg_timezone_names WHERE name = tz
  ) THEN
    RAISE EXCEPTION 'Invalid IANA timezone: %', tz
      USING ERRCODE = '22023';
  END IF;
  UPDATE public.profiles
     SET timezone = tz
   WHERE id = auth.uid();
END;
$$;

REVOKE ALL    ON FUNCTION public.update_my_timezone(TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.update_my_timezone(TEXT) TO authenticated;

COMMENT ON FUNCTION public.update_my_timezone(TEXT) IS
  'Updates the caller''s profiles.timezone after validating the '
  'input against pg_timezone_names. Raises 22023 on null or non-'
  'IANA values, 42501 when unauthenticated. SECURITY DEFINER + '
  'scoped to auth.uid() so a tampered client cannot tamper with '
  'another user''s timezone.';

-- =============================================================================
-- After this migration applies :
--
--   - existing builds (0.1.0+37 and earlier) keep working as-is :
--     they never reference the new column, every consumer treats
--     NULL as UTC,
--   - the next Flutter build that wires flutter_timezone (Phase B)
--     will call update_my_timezone() at cold start to populate the
--     row,
--   - any future Edge Function / cron job that needs a user's
--     local hour reads `SELECT timezone FROM profiles WHERE id=X`
--     and applies `COALESCE(timezone, 'UTC')`,
--   - a tampered client cannot insert garbage : the trigger
--     rejects non-IANA values at the DB level even on direct REST
--     UPDATEs.
-- =============================================================================
