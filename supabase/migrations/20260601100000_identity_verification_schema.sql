-- =============================================================================
-- DateNow — Phase 1 of the Didit identity verification rollout
--
-- DORMANT migration. Adds the database surface the Didit pipeline will
-- need (profile columns, audit table, RPC, defensive triggers) WITHOUT
-- wiring any of it to a Flutter UI or to a find-date gate. Existing
-- test accounts are grandfathered so the team can keep developing
-- against verified states until the Edge Function + onboarding step
-- ship in Phases 2-6.
--
-- Decision tree the eventual `didit-webhook` Edge Function will drive :
--
--                            ┌─────────────────────────┐
--                            │ Didit verdict received  │
--                            └────────────┬────────────┘
--                                         │
--                  ┌──────────────────────┼──────────────────────┐
--                  │                      │                      │
--             approved                rejected (minor)      rejected (other)
--           age ≥ 18                                            (doc_invalid,
--           face match OK                                        face_mismatch,
--                  │                      │                      liveness_failed)
--                  ▼                      ▼                      │
--   profiles.identity_verified    block account (audit row       ▼
--   profiles.age_verified           kept, app UX shows           user retries
--   profiles.identity_verified_at   "DateNow réservé 18+")       (new IV row)
--   profiles.identity_provider
--   = 'didit'
--
-- The trigger pair below makes sure no client (`authenticated` JWT,
-- `anon`, etc.) can ever write to the four `profiles` identity
-- columns directly. Only `service_role` (used by `didit-webhook`)
-- and `supabase_admin` may. Same defense-in-depth pattern as
-- `user_photos_lock_moderation` (cf.
-- 20260531130000_force_pending_on_insert.sql).
-- =============================================================================

-- ── 1. Enum identity_verification_status ────────────────────────
DO $$ BEGIN
  CREATE TYPE public.identity_verification_status AS ENUM (
    'pending',     -- Didit session created, user has not finished yet
    'in_review',   -- user submitted documents, Didit processing
    'approved',    -- ID + selfie + face match + age ≥ 18 all green
    'rejected',    -- definitive refusal (minor, document_invalid, …)
    'expired'      -- session not completed within Didit's TTL (~30 min)
  );
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;

-- ── 2. profiles : identity columns ──────────────────────────────
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS identity_verified      BOOLEAN     NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS age_verified           BOOLEAN     NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS identity_verified_at   TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS identity_provider      TEXT;

-- ── 3. Grandfather existing accounts ────────────────────────────
-- Every profile row that exists at the moment this migration applies
-- is flipped to verified so the development team's test accounts
-- (and any other pre-launch account) can keep using the app while
-- Phases 2-6 ship. Future signups (post-migration) default to FALSE
-- via the column DEFAULT and the trigger in section 7 — they will
-- have to go through Didit.
--
-- `identity_provider = 'grandfather'` differentiates them from real
-- Didit-verified rows in any future analytics or audit query.
UPDATE public.profiles
   SET identity_verified    = TRUE,
       age_verified         = TRUE,
       identity_verified_at = now(),
       identity_provider    = 'grandfather'
 WHERE identity_verified = FALSE;

-- ── 4. identity_verifications audit table ───────────────────────
-- Holds every Didit session attempt for every user. RLS-protected :
-- only the user can SELECT their own rows ; INSERT / UPDATE happen
-- ONLY through the service_role inside the eventual `didit-webhook`
-- Edge Function. No client-facing write path.
--
-- `age_mismatch` is a STORED generated column : if Didit's extracted
-- age differs from the age the user typed at profile_setup by more
-- than 1 year (single year tolerance for typos / birthday week edge
-- cases), this flips true and the webhook function can route to
-- manual review. Detects users who lied about their DOB during
-- onboarding.
CREATE TABLE IF NOT EXISTS public.identity_verifications (
  id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id              UUID NOT NULL
                         REFERENCES public.profiles(id) ON DELETE CASCADE,
  provider             TEXT NOT NULL DEFAULT 'didit',
  external_session_id  TEXT,                                         -- Didit session_id
  status               public.identity_verification_status
                         NOT NULL DEFAULT 'pending',
  age_over_18          BOOLEAN,                                      -- Didit verdict
  age_claimed          INTEGER,                                      -- from profiles.birth_date at session create
  age_extracted        INTEGER,                                      -- from Didit document scan
  age_mismatch         BOOLEAN GENERATED ALWAYS AS (
                         age_extracted IS NOT NULL
                         AND age_claimed IS NOT NULL
                         AND ABS(age_extracted - age_claimed) > 1
                       ) STORED,
  reject_reason        TEXT,                                         -- 'minor' | 'document_invalid' | 'face_mismatch' | 'liveness_failed' | …
  raw_payload          JSONB,                                        -- full Didit response (audit + GDPR DPIA)
  created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
  submitted_at         TIMESTAMPTZ,                                  -- user finished the Didit flow
  decided_at           TIMESTAMPTZ                                   -- webhook landed the verdict
);

CREATE INDEX IF NOT EXISTS iv_user_recent_idx
  ON public.identity_verifications (user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS iv_session_idx
  ON public.identity_verifications (external_session_id)
  WHERE external_session_id IS NOT NULL;

-- ── 5. RLS on identity_verifications ────────────────────────────
ALTER TABLE public.identity_verifications ENABLE ROW LEVEL SECURITY;

-- User reads their own audit trail (UX : "voir le statut de ma vérif").
DROP POLICY IF EXISTS "iv_select_own" ON public.identity_verifications;
CREATE POLICY "iv_select_own"
  ON public.identity_verifications FOR SELECT
  USING (auth.uid() = user_id);

-- No INSERT / UPDATE policies on purpose — only the service role
-- used by the Didit Edge Functions writes here. A tampered client
-- gets `42501 insufficient_privilege` if it tries to forge a row.

-- ── 6. RPC has_verified_identity ────────────────────────────────
-- Mirrors `has_approved_photo()` (cf. moderation rollout). Returns
-- a single boolean so the Flutter find-date gate can call it before
-- routing to /matching. SECURITY DEFINER + scoped to auth.uid() so
-- a client cannot peek at someone else's state by passing a
-- different UID.
CREATE OR REPLACE FUNCTION public.has_verified_identity()
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(p.identity_verified AND p.age_verified, FALSE)
    FROM public.profiles p
   WHERE p.id = auth.uid();
$$;

REVOKE ALL ON FUNCTION public.has_verified_identity() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.has_verified_identity() TO authenticated;

COMMENT ON FUNCTION public.has_verified_identity() IS
  'Returns true when the caller has BOTH identity_verified AND '
  'age_verified set on their profile row. Drives the find-date gate '
  'and any future feature that must refuse to act on a non-verified '
  'user. SECURITY DEFINER scoped to auth.uid().';

-- ── 7. BEFORE INSERT trigger : force identity cols false on signup
-- Every new profile row inserted by `authenticated` (typically via
-- the `handle_new_user` flow that auto-creates a profile when a
-- Supabase Auth user is created, or via a client UPSERT on first
-- saveProfile call) is forced to identity_verified=FALSE. Without
-- this, a tampered client could POST INSERT with
-- identity_verified=true and bypass Didit entirely.
--
-- Service role (`didit-webhook`) and `postgres` (migrations) bypass
-- the lock — they are the only paths allowed to write these columns.
CREATE OR REPLACE FUNCTION public.profiles_force_unverified_on_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF current_user IN ('service_role', 'postgres', 'supabase_admin') THEN
    RETURN NEW;
  END IF;
  NEW.identity_verified    := FALSE;
  NEW.age_verified         := FALSE;
  NEW.identity_verified_at := NULL;
  NEW.identity_provider    := NULL;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS profiles_force_unverified ON public.profiles;
CREATE TRIGGER profiles_force_unverified
  BEFORE INSERT ON public.profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.profiles_force_unverified_on_insert();

-- ── 8. BEFORE UPDATE trigger : lock identity cols for non-admins
-- Stops `authenticated` clients from setting any of the 4 identity
-- columns via a regular UPDATE on their own profile row. Only fires
-- when one of those columns actually changed — so a normal
-- saveProfile that touches first_name / birth_date / gender / prefs
-- passes through with zero overhead (NEW.identity_verified IS NOT
-- DISTINCT FROM OLD.identity_verified short-circuits to no-op).
CREATE OR REPLACE FUNCTION public.profiles_lock_identity_columns()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF current_user IN ('service_role', 'postgres', 'supabase_admin') THEN
    RETURN NEW;
  END IF;
  IF NEW.identity_verified      IS DISTINCT FROM OLD.identity_verified
     OR NEW.age_verified         IS DISTINCT FROM OLD.age_verified
     OR NEW.identity_verified_at IS DISTINCT FROM OLD.identity_verified_at
     OR NEW.identity_provider    IS DISTINCT FROM OLD.identity_provider
  THEN
    RAISE EXCEPTION
      'profiles identity columns are read-only for role %, '
      'only didit-webhook (service_role) or admin may write them',
      current_user
      USING ERRCODE = '42501';  -- insufficient_privilege
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS profiles_lock_identity ON public.profiles;
CREATE TRIGGER profiles_lock_identity
  BEFORE UPDATE ON public.profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.profiles_lock_identity_columns();

-- =============================================================================
-- After this migration applies :
--
--   - existing accounts are verified (grandfathered with provider='grandfather')
--   - new signups insert with identity_verified=false (DEFAULT + trigger)
--   - Flutter still reads NO identity flag (Phase 4-6 ship that)
--   - find-date gate still works exactly as today (Phase 6 wires it)
--   - any client INSERT/UPDATE attempt on the 4 identity columns is
--     rejected at the schema level — only service_role writes them
--   - the `identity_verifications` audit table is ready to receive
--     Phase 2 INSERTs from the `didit-create-session` Edge Function
--     and the Phase 3 UPDATEs from the `didit-webhook`
-- =============================================================================
