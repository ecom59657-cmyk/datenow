-- Hardens `handle_new_user` against any sub-row INSERT failure so a
-- new auth.users row is NEVER lost just because (say) a CHECK
-- constraint on `user_preferences` or a future column-rename caught
-- the trigger mid-flight.
--
-- Bug the user hit: `signUp via Apple/Google/OTP` returned
--   {"code":"unexpected_failure",
--    "message":"Database error saving new user"}
--
-- Postgres surfaces this generic message whenever the AFTER INSERT
-- trigger on auth.users throws — which rolls back the auth.users
-- INSERT itself. The user is then stuck: they can't sign up AND
-- there's nothing in the DB to diagnose against.
--
-- This migration keeps the trigger's purpose (provisioning the four
-- public.* rows) but:
--
--   1. Wraps each sub-INSERT in its own BEGIN/EXCEPTION block, so a
--      failure in (e.g.) `subscriptions` doesn't take down `profiles`
--      and doesn't roll back auth.users. Each failure RAISES a
--      WARNING that surfaces in Supabase → Logs → Postgres.
--   2. Uses `ON CONFLICT DO NOTHING` so a retry — or a manual
--      provisioning via the new `ensure_profile_exists()` RPC — is
--      idempotent.
--   3. Keeps the 18+ check as a hard `RAISE EXCEPTION` (the only
--      reason we WANT signup to fail).
--   4. Logs the raw raw_user_meta_data via `RAISE LOG` so we can see
--      exactly what metadata Apple / Google / signInWithOtp sent.
--
-- Also adds `ensure_profile_exists()` — a SECURITY DEFINER RPC the
-- client calls after verifyOTP / signInWithIdToken to self-heal any
-- missing row (e.g. trigger fired but `profiles` INSERT silently
-- skipped due to a transient FK / RLS edge case). Safe to call on
-- every login — it's a no-op when all rows already exist.

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_first_name TEXT;
  v_birth_date DATE;
  v_raw_first TEXT := NEW.raw_user_meta_data->>'first_name';
  v_raw_dob   TEXT := NEW.raw_user_meta_data->>'birth_date';
BEGIN
  RAISE LOG
    'handle_new_user[%]: provider=% email=% meta_first=% meta_dob=%',
    NEW.id,
    coalesce(NEW.raw_app_meta_data->>'provider', 'email'),
    NEW.email,
    coalesce(v_raw_first, '<null>'),
    coalesce(v_raw_dob,   '<null>');

  v_first_name := NULLIF(trim(coalesce(v_raw_first, '')), '');

  IF v_raw_dob IS NOT NULL AND length(trim(v_raw_dob)) > 0 THEN
    BEGIN
      v_birth_date := v_raw_dob::date;
    EXCEPTION WHEN others THEN
      RAISE WARNING
        'handle_new_user[%]: birth_date parse failed for "%" — %',
        NEW.id, v_raw_dob, SQLERRM;
      v_birth_date := NULL;
    END;
  END IF;

  -- Hard age gate (still the only reason we abort the auth.users
  -- INSERT). If the metadata explicitly says the user is under 18,
  -- refuse the signup with a humane message.
  IF v_birth_date IS NOT NULL
     AND v_birth_date > (CURRENT_DATE - INTERVAL '18 years') THEN
    RAISE EXCEPTION 'DateNow is reserved for people 18 and older.';
  END IF;

  -- profiles
  BEGIN
    INSERT INTO public.profiles (id, first_name, birth_date)
    VALUES (NEW.id, v_first_name, v_birth_date)
    ON CONFLICT (id) DO NOTHING;
  EXCEPTION WHEN others THEN
    RAISE WARNING
      'handle_new_user[%]: profiles INSERT failed — %',
      NEW.id, SQLERRM;
  END;

  -- user_preferences
  BEGIN
    INSERT INTO public.user_preferences (user_id)
    VALUES (NEW.id)
    ON CONFLICT (user_id) DO NOTHING;
  EXCEPTION WHEN others THEN
    RAISE WARNING
      'handle_new_user[%]: user_preferences INSERT failed — %',
      NEW.id, SQLERRM;
  END;

  -- user_settings
  BEGIN
    INSERT INTO public.user_settings (user_id)
    VALUES (NEW.id)
    ON CONFLICT (user_id) DO NOTHING;
  EXCEPTION WHEN others THEN
    RAISE WARNING
      'handle_new_user[%]: user_settings INSERT failed — %',
      NEW.id, SQLERRM;
  END;

  -- subscriptions
  BEGIN
    INSERT INTO public.subscriptions (user_id)
    VALUES (NEW.id)
    ON CONFLICT (user_id) DO NOTHING;
  EXCEPTION WHEN others THEN
    RAISE WARNING
      'handle_new_user[%]: subscriptions INSERT failed — %',
      NEW.id, SQLERRM;
  END;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.handle_new_user IS
  'Provisions profiles + user_preferences + user_settings + '
  'subscriptions for a newly-created auth.users row. Hardened: each '
  'sub-INSERT is wrapped in its own BEGIN/EXCEPTION block so a '
  'partial failure does NOT roll back the auth.users INSERT itself. '
  'Missing rows can be repaired via public.ensure_profile_exists().';

-- ---------------------------------------------------------------------------
-- Self-heal RPC: ensure_profile_exists()
--
-- Called by the client after verifyOTP / signInWithIdToken. Idempotent
-- top-up — re-creates whichever of the four base rows are missing for
-- the calling auth.uid(). Returns void on success, raises if the
-- caller is not authenticated.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.ensure_profile_exists()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'ensure_profile_exists: not authenticated' USING
      ERRCODE = '42501';
  END IF;

  INSERT INTO public.profiles (id)
  VALUES (v_uid)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.user_preferences (user_id)
  VALUES (v_uid)
  ON CONFLICT (user_id) DO NOTHING;

  INSERT INTO public.user_settings (user_id)
  VALUES (v_uid)
  ON CONFLICT (user_id) DO NOTHING;

  INSERT INTO public.subscriptions (user_id)
  VALUES (v_uid)
  ON CONFLICT (user_id) DO NOTHING;
END;
$$;

COMMENT ON FUNCTION public.ensure_profile_exists IS
  'Idempotent client-side top-up: re-creates any of '
  '{profiles, user_preferences, user_settings, subscriptions} that '
  'are missing for auth.uid(). Called from the Flutter client right '
  'after verifyOTP / signInWithIdToken so an OAuth/OTP signup whose '
  'trigger partially failed self-heals on the very next login.';

REVOKE ALL ON FUNCTION public.ensure_profile_exists() FROM public;
GRANT EXECUTE ON FUNCTION public.ensure_profile_exists() TO authenticated;
