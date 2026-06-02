-- =============================================================================
-- DateNow — V1 Hardening Sprint, Commit 2 : 5-min call cap (server-side)
--                                            + storage bucket size/mime caps
--
-- Closes two findings from the security audit :
--
--   1. Pass 7 E4 (BLOCKER) : The "5-min Agora call" promise was
--      enforced ONLY by the Flutter client timer (AppConfig.maxCallDuration).
--      The server-side `room_expires_at` was set to 30 min, so a
--      tampered client could keep the call open up to 30 min — burning
--      Agora minutes and turning the app into a free long-form video
--      chat. We fix that by resetting `room_expires_at = now() + 5 min`
--      the moment the call goes 'live' (= both peers accepted). The
--      existing pg_cron sweep (mm_sweep_timeouts, every minute) then
--      closes stragglers automatically.
--
--   2. Pass 5 M3 (MEDIUM) : The `profile-photos` storage bucket had
--      neither `file_size_limit` nor `allowed_mime_types`, letting a
--      tampered client upload arbitrary 100+ MB blobs of any MIME
--      type. We cap at 5 MB (matches Didit's own image limit on
--      face-match) and restrict to image/jpeg, image/png, image/webp.
--
-- Migration safety :
--   - mm_accept_match : pure CREATE OR REPLACE of the existing
--     function ; bodies copied verbatim from
--     20260528120000_matching_engine_v2.sql except the one CASE
--     branch swapped from COALESCE(..., 30 min) to a fresh 5-min
--     window every time status transitions to 'live'.
--   - storage.buckets UPDATE on an existing row — idempotent.
--   - No new policies, no RLS change, no data migration.
-- =============================================================================

-- ── 1. mm_accept_match (re-created with 5-min room_expires_at) ──
CREATE OR REPLACE FUNCTION public.mm_accept_match(p_call_id UUID)
RETURNS TABLE(state TEXT, both_ready BOOLEAN, channel_name TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_self    UUID := auth.uid();
    v_caller  UUID;
    v_callee  UUID;
    v_status  TEXT;
    v_deadline TIMESTAMPTZ;
    v_cready  BOOLEAN;
    v_eready  BOOLEAN;
    v_channel TEXT;
BEGIN
    IF v_self IS NULL THEN
        RAISE EXCEPTION 'unauthorized' USING ERRCODE = '28000';
    END IF;

    -- Verrou ligne pour éviter une race entre les deux ready.
    SELECT caller_id, callee_id, status, accept_expires_at,
           caller_ready, callee_ready, channel_name
      INTO v_caller, v_callee, v_status, v_deadline,
           v_cready, v_eready, v_channel
      FROM public.calls
     WHERE id = p_call_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'call_not_found' USING ERRCODE = '42704';
    END IF;
    IF v_self NOT IN (v_caller, v_callee) THEN
        RAISE EXCEPTION 'not_a_participant' USING ERRCODE = '42501';
    END IF;
    IF v_status <> 'waiting' THEN
        RAISE EXCEPTION 'call_not_waiting' USING ERRCODE = '23P01';
    END IF;
    IF v_deadline IS NOT NULL AND v_deadline < now() THEN
        RAISE EXCEPTION 'accept_window_expired' USING ERRCODE = '23P01';
    END IF;

    IF v_self = v_caller THEN
        v_cready := true;
    ELSE
        v_eready := true;
    END IF;

    UPDATE public.calls
       SET caller_ready = v_cready,
           callee_ready = v_eready,
           status = CASE WHEN v_cready AND v_eready THEN 'live' ELSE 'waiting' END,
           -- V1 HARDENING (Pass 7 E4) :
           -- When the call transitions to 'live', RESET the room
           -- expiry to now() + 5 minutes (was: COALESCE keep, default
           -- 30 min). The 5-min business cap is now server-enforced
           -- via the existing mm_sweep_timeouts cron.
           --
           -- A tampered client that bypasses the Flutter
           -- AppConfig.maxCallDuration timer can no longer extend
           -- the call beyond the contracted 5-min window — the cron
           -- will end the call at the next minute boundary.
           --
           -- We use 5 min + 30 s buffer (= interval '5 minutes 30
           -- seconds') so that a legitimate 5-min countdown reaches
           -- exactly 0 client-side before the server starts forcing
           -- the close. The buffer absorbs network latency, clock
           -- skew, and the up-to-60s granularity of the cron job.
           room_expires_at = CASE
                WHEN v_cready AND v_eready
                THEN now() + interval '5 minutes 30 seconds'
                ELSE room_expires_at
           END
     WHERE id = p_call_id;

    IF v_cready AND v_eready THEN
        INSERT INTO public.match_history (user_a, user_b, call_id, outcome)
        VALUES (LEAST(v_caller, v_callee), GREATEST(v_caller, v_callee),
                p_call_id, 'accepted')
        ON CONFLICT DO NOTHING;
    END IF;

    RETURN QUERY
        SELECT CASE WHEN v_cready AND v_eready THEN 'live' ELSE 'waiting' END,
               (v_cready AND v_eready),
               v_channel;
END $$;

-- ── 2. profile-photos storage bucket caps ───────────────────────
-- Idempotent UPDATE — runs safely on every fresh-DB replay because
-- the INSERT in 20260513120300_storage.sql creates the row, and
-- this UPDATE just tightens its constraints.
UPDATE storage.buckets
   SET file_size_limit    = 5242880,                                       -- 5 MB
       allowed_mime_types = ARRAY['image/jpeg','image/png','image/webp']
 WHERE id = 'profile-photos';

-- =============================================================================
-- After this migration applies :
--
--   - Calls that go 'live' get a fresh 5-min 30 s room_expires_at,
--     overriding any pre-existing 30-min value set at find_match
--     time. The pg_cron mm_sweep_timeouts continues to close calls
--     past expiry at the next minute boundary.
--   - Profile photo uploads >5 MB are rejected by the storage API
--     with 413 ; non-image MIME types are rejected with 415. Vision
--     API never receives garbage payloads.
--   - No client-side change required ; AppConfig.maxCallDuration = 5
--     min stays the source of truth for the COUNTDOWN, the server is
--     now the source of truth for the HARD STOP.
-- =============================================================================
