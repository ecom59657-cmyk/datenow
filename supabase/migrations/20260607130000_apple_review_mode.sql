-- =============================================================================
-- DateNow — Apple Review mode (demo account + seeded data)
--
-- Goal: let App Review test the app end-to-end in < 2 min without a second
-- live user, without real OTP delivery and without payment — using REAL
-- screens and REAL data (App Store Guideline 2.3.1 compliant: nothing is
-- hidden or reviewer-only in the app behaviour).
--
-- This migration:
--   1. Adds profiles.is_apple_review (explicit marker for demo accounts).
--   2. Provides seed_apple_review(review_id, anna_id) — an idempotent
--      SECURITY DEFINER RPC that seeds the Reviewer profile, the Anna demo
--      profile, a pre-created match, a conversation and the demo messages.
--
-- The two auth.users rows are created by the companion Edge Function
-- `seed-apple-review` via the Admin API (the supported, version-safe way),
-- which then calls this RPC. We deliberately do NOT insert into auth.users
-- from SQL.
--
-- Anna is seeded WITHOUT a `location`, so the existing matching gate
-- (`location IS NOT NULL` in find_best_live_candidate_v1) already excludes
-- her from the real candidate pool — no change to the matching engine.
--
-- Idempotent: safe to run / re-run.
-- =============================================================================

-- 1. Explicit demo marker -----------------------------------------------------
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS is_apple_review BOOLEAN NOT NULL DEFAULT false;

COMMENT ON COLUMN public.profiles.is_apple_review IS
  'TRUE only for the Apple Review demo account and the Anna demo profile. '
  'Used to flag demo data; never set for real users.';

-- 2. Seed RPC -----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.seed_apple_review(
  p_review UUID,
  p_anna   UUID
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_a    UUID := LEAST(p_review, p_anna);
  v_b    UUID := GREATEST(p_review, p_anna);
  v_conv UUID;
  v_base TIMESTAMPTZ := now() - INTERVAL '30 minutes';
BEGIN
  -- Reviewer profile (Reviewer, 30, male, seeking female) ---------------------
  INSERT INTO public.profiles (id, first_name, birth_date, gender, sexual_orientation, is_apple_review)
  VALUES (p_review, 'Reviewer', (CURRENT_DATE - INTERVAL '30 years')::date, 'male', 'straight', true)
  ON CONFLICT (id) DO UPDATE
    SET first_name = EXCLUDED.first_name, is_apple_review = true;

  -- Anna demo profile (Anna, 28, female) — NO location => excluded from pool --
  INSERT INTO public.profiles (id, first_name, birth_date, gender, sexual_orientation, is_apple_review)
  VALUES (p_anna, 'Anna', (CURRENT_DATE - INTERVAL '28 years')::date, 'female', 'straight', true)
  ON CONFLICT (id) DO UPDATE
    SET first_name = EXCLUDED.first_name, is_apple_review = true;

  -- Reviewer preferences (women, 25-40, 50 km, immediate) ---------------------
  INSERT INTO public.user_preferences
    (user_id, seeking_genders, seeking_age_min, seeking_age_max, max_distance_km, intentions, interests, availability)
  VALUES
    (p_review, ARRAY['female'], 25, 40, 50, ARRAY['feeling'], ARRAY['music','travel','food'], 'immediate')
  ON CONFLICT (user_id) DO UPDATE SET
    seeking_genders = EXCLUDED.seeking_genders,
    seeking_age_min = EXCLUDED.seeking_age_min,
    seeking_age_max = EXCLUDED.seeking_age_max,
    max_distance_km = EXCLUDED.max_distance_km,
    availability    = EXCLUDED.availability;

  INSERT INTO public.user_preferences
    (user_id, seeking_genders, seeking_age_min, seeking_age_max, max_distance_km, availability)
  VALUES
    (p_anna, ARRAY['male'], 25, 45, 50, 'immediate')
  ON CONFLICT (user_id) DO NOTHING;

  -- Pre-created mutual match (93% compatibility) ------------------------------
  INSERT INTO public.matches (user_a_id, user_b_id, compatibility_score, status)
  VALUES (v_a, v_b, 93, 'conversation_open')
  ON CONFLICT (user_a_id, user_b_id) DO NOTHING;

  -- Conversation --------------------------------------------------------------
  SELECT id INTO v_conv
  FROM public.conversations
  WHERE user_a_id = v_a AND user_b_id = v_b;

  IF v_conv IS NULL THEN
    INSERT INTO public.conversations (user_a_id, user_b_id)
    VALUES (v_a, v_b)
    RETURNING id INTO v_conv;
  END IF;

  -- Demo messages (only if the conversation is empty => idempotent) -----------
  IF NOT EXISTS (SELECT 1 FROM public.messages WHERE conversation_id = v_conv) THEN
    INSERT INTO public.messages (conversation_id, sender_id, body, created_at, read_at) VALUES
      (v_conv, p_anna,   'Hello sympa ce premier date !',                     v_base + INTERVAL '0 minutes', now()),
      (v_conv, p_review, 'C''est clair ! À quand une partie 2 ?',             v_base + INTERVAL '1 minutes', now()),
      (v_conv, p_anna,   'Tout dépend de tes dispos 😉',                       v_base + INTERVAL '2 minutes', now()),
      (v_conv, p_review, 'On peut se voir la semaine prochaine si ça te va ?', v_base + INTERVAL '3 minutes', now()),
      (v_conv, p_anna,   'Carrément ! On part sur mardi ?',                    v_base + INTERVAL '4 minutes', NULL),
      (v_conv, p_anna,   'Entendu ! 19h ?',                                    v_base + INTERVAL '5 minutes', NULL);
  END IF;
END;
$$;

-- The companion Edge Function (service_role) invokes this after creating the
-- two auth users. Not exposed to normal clients.
REVOKE ALL ON FUNCTION public.seed_apple_review(UUID, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.seed_apple_review(UUID, UUID) TO service_role;
