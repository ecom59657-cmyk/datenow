-- =============================================================================
-- DateNow — `handle_new_user` trigger
--
-- Runs on every `INSERT` into `auth.users`. Reads `first_name` and
-- `birth_date` out of the user's signup metadata (the client passes them
-- via `Supabase.auth.signUp(... data: ...)`), then bootstraps the
-- profile + preferences + settings + subscriptions rows.
--
-- The 18+ rule is enforced THREE times in this file alone:
--   1. Explicit RAISE EXCEPTION when birth_date is missing
--   2. Explicit RAISE EXCEPTION when birth_date < 18 years ago
--   3. Implicitly via the CHECK constraint on `profiles.birth_date`
--
-- All three live in the same transaction as the auth-user insert, so a
-- failure rolls back the signup itself — no orphan auth.users rows.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_first_name TEXT := NEW.raw_user_meta_data->>'first_name';
  v_birth_date_raw TEXT := NEW.raw_user_meta_data->>'birth_date';
  v_birth_date DATE;
BEGIN
  IF v_first_name IS NULL OR length(trim(v_first_name)) = 0 THEN
    RAISE EXCEPTION 'first_name is required at sign up';
  END IF;

  IF v_birth_date_raw IS NULL OR length(trim(v_birth_date_raw)) = 0 THEN
    RAISE EXCEPTION 'birth_date is required at sign up';
  END IF;

  BEGIN
    v_birth_date := v_birth_date_raw::date;
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'birth_date must be a valid ISO-8601 date (got %)', v_birth_date_raw;
  END;

  IF v_birth_date > (CURRENT_DATE - INTERVAL '18 years') THEN
    RAISE EXCEPTION 'DateNow is reserved for people 18 and older.';
  END IF;

  INSERT INTO public.profiles (id, first_name, birth_date)
  VALUES (NEW.id, trim(v_first_name), v_birth_date);

  INSERT INTO public.user_preferences (user_id) VALUES (NEW.id);
  INSERT INTO public.user_settings   (user_id) VALUES (NEW.id);
  INSERT INTO public.subscriptions   (user_id) VALUES (NEW.id);

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION public.handle_new_user();
