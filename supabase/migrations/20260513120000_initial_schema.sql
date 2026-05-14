-- =============================================================================
-- DateNow — initial schema
--
-- Creates every table the app reads or writes. RLS policies live in a
-- separate migration so this file stays purely structural. Every table
-- mirrors a domain concept in `lib/features/<area>/domain/` — keep both
-- sides in sync when extending the schema.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- profiles
-- -----------------------------------------------------------------------------
-- One row per signed-up user. `id` is the FK to `auth.users` so an account
-- and its profile share a single UUID. The hard 18+ age gate is enforced as
-- a CHECK constraint here AND re-checked by `handle_new_user()` at signup
-- time — frontend validation is layer 1, repository is layer 2, this is
-- layers 3 and 4.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.profiles (
  id                  UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  first_name          TEXT NOT NULL CHECK (length(trim(first_name)) BETWEEN 1 AND 60),
  birth_date          DATE NOT NULL,
  gender              TEXT CHECK (gender IN ('female', 'male', 'non_binary')),
  sexual_orientation  TEXT CHECK (
    sexual_orientation IN (
      'straight', 'gay', 'lesbian', 'bi', 'pan', 'asexual', 'queer'
    )
  ),
  display_name        TEXT,
  avatar_url          TEXT,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),

  -- Hard age gate. Mirrors `kMinAgeYears` in lib/core/utils/age.dart.
  CONSTRAINT profiles_min_age_18 CHECK (
    birth_date <= (CURRENT_DATE - INTERVAL '18 years')
  )
);

CREATE INDEX IF NOT EXISTS profiles_birth_date_idx
  ON public.profiles(birth_date);

-- -----------------------------------------------------------------------------
-- user_preferences
-- -----------------------------------------------------------------------------
-- Matching criteria. Arrays use TEXT for portability; the enum values come
-- from the Dart enums in lib/features/profile_setup/domain/{enums,interest}.dart.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.user_preferences (
  user_id          UUID PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
  seeking_genders  TEXT[] NOT NULL DEFAULT '{}',
  seeking_age_min  INTEGER NOT NULL DEFAULT 18,
  seeking_age_max  INTEGER NOT NULL DEFAULT 80,
  max_distance_km  INTEGER NOT NULL DEFAULT 50,
  intentions       TEXT[] NOT NULL DEFAULT '{}',
  interests        TEXT[] NOT NULL DEFAULT '{}',
  availability     TEXT CHECK (availability IN ('immediate', 'sometime')),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT prefs_age_min_at_least_18 CHECK (seeking_age_min >= 18),
  CONSTRAINT prefs_age_max_realistic   CHECK (seeking_age_max <= 120),
  CONSTRAINT prefs_age_range_valid     CHECK (seeking_age_min <= seeking_age_max),
  CONSTRAINT prefs_distance_positive   CHECK (max_distance_km > 0)
);

-- -----------------------------------------------------------------------------
-- user_photos
-- -----------------------------------------------------------------------------
-- Metadata for each photo. The actual bytes live in the private storage
-- bucket created in 20260513120300_storage.sql. The product rule "photos
-- stay private until a 5-minute date completes" is enforced by both the
-- RLS on this table and the bucket-level RLS on `storage.objects`.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.user_photos (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  storage_path  TEXT NOT NULL,
  position      SMALLINT NOT NULL DEFAULT 0
                  CHECK (position >= 0 AND position < 6),
  is_primary    BOOLEAN NOT NULL DEFAULT false,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),

  UNIQUE (user_id, position)
);

CREATE INDEX IF NOT EXISTS user_photos_user_id_idx
  ON public.user_photos(user_id);

-- -----------------------------------------------------------------------------
-- weekly_suggestions
-- -----------------------------------------------------------------------------
-- The (up to 3) per-week proposals shown in the Discover tab. Reciprocity
-- + a 75 % compatibility floor are enforced by the application server when
-- inserting; the table just stores the result and tracks the lifecycle.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.weekly_suggestions (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id               UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  suggested_user_id     UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  compatibility_score   SMALLINT NOT NULL
                          CHECK (compatibility_score BETWEEN 0 AND 100),
  week_start_date       DATE NOT NULL,
  status                TEXT NOT NULL DEFAULT 'pending'
                          CHECK (status IN (
                            'pending', 'dismissed', 'call_started', 'matched'
                          )),
  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),

  UNIQUE (user_id, suggested_user_id, week_start_date),
  CONSTRAINT suggestions_no_self CHECK (user_id <> suggested_user_id)
);

CREATE INDEX IF NOT EXISTS weekly_suggestions_user_week_idx
  ON public.weekly_suggestions(user_id, week_start_date);

-- -----------------------------------------------------------------------------
-- matches (mutual, post-call)
-- -----------------------------------------------------------------------------
-- Single row per matched pair. The `user_a_id < user_b_id` canonical
-- ordering ensures we never store two rows for the same pair.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.matches (
  id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_a_id            UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  user_b_id            UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  compatibility_score  SMALLINT NOT NULL
                         CHECK (compatibility_score BETWEEN 0 AND 100),
  matched_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
  status               TEXT NOT NULL DEFAULT 'new'
                         CHECK (status IN ('new', 'conversation_open', 'archived')),

  CONSTRAINT matches_no_self  CHECK (user_a_id <> user_b_id),
  CONSTRAINT matches_ordered  CHECK (user_a_id < user_b_id),
  UNIQUE (user_a_id, user_b_id)
);

CREATE INDEX IF NOT EXISTS matches_user_a_idx ON public.matches(user_a_id);
CREATE INDEX IF NOT EXISTS matches_user_b_idx ON public.matches(user_b_id);

-- -----------------------------------------------------------------------------
-- calls (5-minute live dates)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.calls (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  caller_id         UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  callee_id         UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  suggestion_id     UUID REFERENCES public.weekly_suggestions(id) ON DELETE SET NULL,
  started_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  ended_at          TIMESTAMPTZ,
  duration_seconds  INTEGER CHECK (duration_seconds >= 0),
  caller_decision   TEXT CHECK (caller_decision IN ('match', 'pass')),
  callee_decision   TEXT CHECK (callee_decision IN ('match', 'pass')),

  CONSTRAINT calls_no_self CHECK (caller_id <> callee_id)
);

CREATE INDEX IF NOT EXISTS calls_caller_idx ON public.calls(caller_id);
CREATE INDEX IF NOT EXISTS calls_callee_idx ON public.calls(callee_id);

-- -----------------------------------------------------------------------------
-- blocked_users
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.blocked_users (
  user_id          UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  blocked_user_id  UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  blocked_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  reason           TEXT,

  PRIMARY KEY (user_id, blocked_user_id),
  CONSTRAINT no_self_block CHECK (user_id <> blocked_user_id)
);

-- -----------------------------------------------------------------------------
-- reports
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.reports (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  reporter_id       UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
  reported_user_id  UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  reason            TEXT NOT NULL,
  details           TEXT,
  status            TEXT NOT NULL DEFAULT 'pending'
                      CHECK (status IN ('pending', 'reviewed', 'dismissed')),
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS reports_status_idx ON public.reports(status);

-- -----------------------------------------------------------------------------
-- subscriptions
-- -----------------------------------------------------------------------------
-- One row per user. The `stripe_subscription_id` will be populated by the
-- Stripe webhook handler when checkout completes — kept here so the rest of
-- the schema is one self-contained piece.
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
-- updated_at trigger
-- -----------------------------------------------------------------------------
-- Generic helper applied to every mutable table that exposes `updated_at`.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_profiles_updated_at
  BEFORE UPDATE ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE TRIGGER trg_user_preferences_updated_at
  BEFORE UPDATE ON public.user_preferences
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE TRIGGER trg_subscriptions_updated_at
  BEFORE UPDATE ON public.subscriptions
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE TRIGGER trg_user_settings_updated_at
  BEFORE UPDATE ON public.user_settings
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
