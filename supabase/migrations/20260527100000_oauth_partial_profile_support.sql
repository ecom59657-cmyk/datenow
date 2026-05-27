-- =============================================================================
-- DateNow — relax handle_new_user for OAuth flows (auth sub-phase D)
--
-- Before this migration the trigger raised an EXCEPTION when first_name
-- or birth_date was missing from the signup metadata. That's fine for
-- the email-OTP flow (the client passes both in `data: …`), but it
-- breaks every OAuth provider: Apple Sign In never provides birth_date,
-- and only provides first_name on the very first sign-in. The result
-- before this fix: any Apple Sign In attempt failed inside the trigger
-- and rolled back the auth.users insert entirely — the user could
-- never even reach the in-app onboarding.
--
-- Strategy: allow OAuth signups to create a PARTIAL profile (first_name
-- + birth_date NULL or empty). The client-side `UserProfile.isComplete`
-- gate + the router redirect already force the user through the
-- profile-setup flow before they can reach /home or matching — so the
-- only thing we lose by relaxing the trigger is the "synchronous"
-- exception. The 18+ check is moved to:
--   * the app's Cupertino picker (can't physically pick < 18),
--   * the Validators.birthDate client check,
--   * the profiles.birth_date CHECK constraint (now conditional on
--     non-null),
--   * the Supabase RLS that gates matching on a complete profile
--     (claim_match raises peer_not_ready / similar already).
-- =============================================================================

-- ── Schema: profiles columns become nullable ──────────────────────────
ALTER TABLE public.profiles
  ALTER COLUMN first_name DROP NOT NULL,
  ALTER COLUMN birth_date DROP NOT NULL;

-- Keep the 18+ floor at the DB level, conditionally on birth_date
-- being set. NULL is allowed (OAuth in progress) but any real value
-- must respect the 18-year minimum.
ALTER TABLE public.profiles
  DROP CONSTRAINT IF EXISTS profiles_min_age_18;
ALTER TABLE public.profiles
  ADD CONSTRAINT profiles_min_age_18 CHECK (
    birth_date IS NULL
    OR birth_date <= (CURRENT_DATE - INTERVAL '18 years')
  );

-- ── Trigger: do not RAISE on missing metadata ─────────────────────────
-- Insert what we have; the app will collect the rest via profile-setup.
-- The age check still runs when birth_date IS provided (email OTP path).
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_first_name_raw TEXT := NEW.raw_user_meta_data->>'first_name';
  v_birth_date_raw TEXT := NEW.raw_user_meta_data->>'birth_date';
  v_first_name TEXT;
  v_birth_date DATE;
BEGIN
  -- Normalise: empty-string -> null so the profile is unambiguously
  -- "to be completed by the user".
  IF v_first_name_raw IS NOT NULL AND length(trim(v_first_name_raw)) > 0 THEN
    v_first_name := trim(v_first_name_raw);
  END IF;

  -- Birth_date: try to parse, fall back to NULL on any failure (OAuth
  -- always falls here since Apple/Google never provide it).
  IF v_birth_date_raw IS NOT NULL AND length(trim(v_birth_date_raw)) > 0 THEN
    BEGIN
      v_birth_date := v_birth_date_raw::date;
    EXCEPTION WHEN others THEN
      v_birth_date := NULL;
    END;
  END IF;

  -- Age check ONLY if birth_date was provided. OAuth flows skip this
  -- here and are checked client-side at profile-setup (Cupertino picker
  -- + Validators.birthDate + the CHECK constraint above).
  IF v_birth_date IS NOT NULL
     AND v_birth_date > (CURRENT_DATE - INTERVAL '18 years') THEN
    RAISE EXCEPTION 'DateNow is reserved for people 18 and older.';
  END IF;

  INSERT INTO public.profiles (id, first_name, birth_date)
  VALUES (NEW.id, v_first_name, v_birth_date);

  INSERT INTO public.user_preferences (user_id) VALUES (NEW.id);
  INSERT INTO public.user_settings   (user_id) VALUES (NEW.id);
  INSERT INTO public.subscriptions   (user_id) VALUES (NEW.id);

  RETURN NEW;
END;
$$;

-- Trigger itself is already on auth.users from the original migration;
-- re-attaching defensively in case a partial migration left it
-- dangling.
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION public.handle_new_user();
