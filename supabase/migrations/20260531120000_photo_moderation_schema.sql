-- =============================================================================
-- DateNow — photo moderation schema (Phase 1 of the V1 rollout)
--
-- Adds a strict status lifecycle on every `user_photos` row so no photo
-- can become publicly visible until it has been validated by the
-- `analyze-profile-photo` Edge Function (Google Cloud Vision SafeSearch
-- + Face Detection).
--
-- Lifecycle :
--
--   pending → analyzing → approved | rejected | manual_review
--                                ↑           ↑
--                       (re-upload from)  (admin decision in
--                        Flutter UX)      Supabase Studio →
--                                          moderation_queue.decision)
--
-- Grandfather rule : every photo already in the table at migration
-- time is flipped to `approved`. Without this, the deploy would
-- instantly hide every existing profile photo from every existing
-- user — TestFlight regression.
--
-- The actual moderation runtime (Edge Function + Google Vision wiring)
-- ships in the next commit. This migration is **dormant** : after
-- push, new photos default to `pending` but no decision pipeline yet
-- evaluates them. The Flutter find-date gate will treat `pending` as
-- "no approved photo" so new users without a moderated photo are
-- correctly blocked from launching a date — old users keep their
-- grandfathered approval.
-- =============================================================================

-- ── photo_status enum ────────────────────────────────────────────
CREATE TYPE public.photo_status AS ENUM (
  'pending',         -- just uploaded, waiting for analyze-profile-photo
  'analyzing',       -- Edge Function in-flight
  'approved',        -- safe + face count = 1 + cleared SafeSearch
  'rejected',        -- automatic refusal (nsfw / multi-face / no-face / …)
  'manual_review'    -- automatic doubt (low confidence) → admin in Studio
);

-- ── user_photos: status column + moderation metadata ─────────────
ALTER TABLE public.user_photos
  ADD COLUMN IF NOT EXISTS status              public.photo_status
                                               NOT NULL DEFAULT 'pending',
  ADD COLUMN IF NOT EXISTS moderation_provider TEXT,
  ADD COLUMN IF NOT EXISTS moderation_score    JSONB,
  ADD COLUMN IF NOT EXISTS moderation_at       TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS reject_reason       TEXT;

-- Grandfather every existing row to `approved` so the rollout is
-- transparent for users who already uploaded their photo. WHERE clause
-- is defensive: in a fresh deploy the column was just added and
-- everything is 'pending'; in a re-run the WHERE protects rows that
-- legitimately moved past 'pending'.
UPDATE public.user_photos
   SET status = 'approved'
 WHERE status = 'pending'
   AND created_at < now();

-- Read-side index : the "do you have an approved photo" check runs
-- on every find-date tap. Partial index keeps it tiny.
CREATE INDEX IF NOT EXISTS user_photos_approved_idx
  ON public.user_photos (user_id)
  WHERE status = 'approved';

-- ── moderation_queue : doubtful cases for human review ───────────
CREATE TABLE IF NOT EXISTS public.moderation_queue (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  photo_id     UUID NOT NULL REFERENCES public.user_photos(id) ON DELETE CASCADE,
  user_id      UUID NOT NULL REFERENCES public.profiles(id)    ON DELETE CASCADE,
  reason       TEXT NOT NULL,
  ai_payload   JSONB NOT NULL,
  reviewer_id  UUID REFERENCES public.profiles(id),
  decision     TEXT,
  decided_at   TIMESTAMPTZ,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Open-review fast-lookup. WHERE clause keeps the index small.
CREATE INDEX IF NOT EXISTS moderation_queue_open_idx
  ON public.moderation_queue (created_at)
  WHERE decision IS NULL;

-- No user-facing policies — admin reviews via Supabase Studio
-- (service role bypasses RLS). Keeping the table RLS-enabled makes
-- accidental anon reads impossible.
ALTER TABLE public.moderation_queue ENABLE ROW LEVEL SECURITY;

-- ── moderation_audit_log : every verdict for forensic trail ──────
CREATE TABLE IF NOT EXISTS public.moderation_audit_log (
  id           BIGSERIAL PRIMARY KEY,
  photo_id     UUID NOT NULL,
  user_id      UUID NOT NULL,
  event        TEXT NOT NULL,    -- 'submitted' | 'approved' | 'rejected' | 'manual_review' | 'admin_approve' | 'admin_reject'
  provider     TEXT,             -- 'google_vision' | 'manual' | …
  payload      JSONB,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS moderation_audit_log_user_idx
  ON public.moderation_audit_log (user_id, created_at DESC);

ALTER TABLE public.moderation_audit_log ENABLE ROW LEVEL SECURITY;

-- ── RPC : has the caller got at least one approved photo? ────────
-- Returns boolean. Used by the Flutter find-date gate as the
-- authoritative answer to "can this user launch a date right now?".
-- SECURITY DEFINER + auth.uid() coupling means a client cannot ever
-- query someone else's approval state via this RPC.
CREATE OR REPLACE FUNCTION public.has_approved_photo()
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.user_photos
     WHERE user_id = auth.uid()
       AND status = 'approved'
  );
$$;

REVOKE ALL ON FUNCTION public.has_approved_photo() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.has_approved_photo() TO authenticated;

COMMENT ON FUNCTION public.has_approved_photo() IS
  'Returns true when the caller (auth.uid()) has at least one user_photos '
  'row with status = ''approved''. Drives the find-date gate and any '
  'feature that must refuse to act on a user without a moderated photo.';
