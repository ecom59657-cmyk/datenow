-- =============================================================================
-- DateNow — Shared call session state
--
-- Until now the `public.calls` table existed but was never written to. The
-- call lifecycle lived purely client-side, so when one user hung up the
-- other side kept ringing because it had no way to learn the call had
-- ended.
--
-- This migration is fully self-contained: it (re-)creates the `calls`
-- table if absent, then extends it with the columns a synchronised
-- session needs (status / ended_by / channel_name) and turns on Realtime.
--
-- Idempotent: every statement uses IF NOT EXISTS, DROP-then-CREATE or a
-- conditional DO block so re-running on a partially-migrated database
-- never fails.
-- =============================================================================

-- 1. Base table — matches the original schema, minus the FK to
--    weekly_suggestions which itself may not exist on partial migrations.
CREATE TABLE IF NOT EXISTS public.calls (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  caller_id         UUID NOT NULL
                       REFERENCES public.profiles(id) ON DELETE CASCADE,
  callee_id         UUID NOT NULL
                       REFERENCES public.profiles(id) ON DELETE CASCADE,
  suggestion_id     UUID,
  started_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  ended_at          TIMESTAMPTZ,
  duration_seconds  INTEGER CHECK (duration_seconds >= 0),
  caller_decision   TEXT CHECK (caller_decision IN ('match', 'pass')),
  callee_decision   TEXT CHECK (callee_decision IN ('match', 'pass')),

  CONSTRAINT calls_no_self CHECK (caller_id <> callee_id)
);

CREATE INDEX IF NOT EXISTS calls_caller_idx ON public.calls(caller_id);
CREATE INDEX IF NOT EXISTS calls_callee_idx ON public.calls(callee_id);

-- 2. New columns for shared lifecycle.
ALTER TABLE public.calls
  ADD COLUMN IF NOT EXISTS status TEXT NOT NULL DEFAULT 'live';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'calls_status_check'
      AND conrelid = 'public.calls'::regclass
  ) THEN
    ALTER TABLE public.calls
      ADD CONSTRAINT calls_status_check
      CHECK (status IN ('waiting', 'live', 'ended'));
  END IF;
END $$;

ALTER TABLE public.calls
  ADD COLUMN IF NOT EXISTS ended_by UUID
    REFERENCES public.profiles(id) ON DELETE SET NULL;

ALTER TABLE public.calls
  ADD COLUMN IF NOT EXISTS channel_name TEXT;

CREATE INDEX IF NOT EXISTS calls_channel_name_idx
  ON public.calls(channel_name);

-- 3. RLS — enable + the policy from the original 20260513120100 file may
--    have been skipped on this database; (re-)create it here so call rows
--    can be inserted / read / updated by their two participants.
ALTER TABLE public.calls ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "calls_all_participant" ON public.calls;
CREATE POLICY "calls_all_participant"
  ON public.calls FOR ALL
  USING (auth.uid() = caller_id OR auth.uid() = callee_id)
  WITH CHECK (auth.uid() = caller_id OR auth.uid() = callee_id);

-- 4. Enable Postgres logical replication so clients can subscribe to
--    row-level changes via Supabase Realtime.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename = 'calls'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.calls;
  END IF;
END $$;
