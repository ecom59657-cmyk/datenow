-- =============================================================================
-- DateNow — V1 Hardening Sprint, Commit 4 :
--           Lock direct INSERT on `calls` + `matches` ;
--           introduce SECURITY DEFINER RPCs as the ONLY write paths.
--
-- Closes Pass 5 H2 (HIGH) and Pass 5 M1 (MEDIUM).
--
-- Before this commit :
--   - `calls_all_participant` was a FOR ALL policy allowing any
--     participant to INSERT directly. The Discover-driven
--     `CallSessionRepository.open()` exploited this with a
--     two-step INSERT (status='live') + UPDATE (channel_name).
--     A tampered client could fabricate a `calls` row with any
--     callee_id, bypassing the v2 queue + scoring + ban check.
--   - `matches_all_participant` was likewise FOR ALL. The
--     `reveal_repository.createMatch` did a direct upsert with
--     no server-side verification that BOTH peers had a
--     `decision='match'` reveal on the same call. A tampered
--     client could forge a `matches` row.
--
-- After this commit :
--   - Two new SECURITY DEFINER RPCs handle every legitimate
--     write : `create_call_for_discover()` (Discover happy path)
--     and `create_match_if_mutual()` (post-reveal match
--     confirmation). Both validate the caller server-side.
--   - The participant FOR ALL policies on `calls` and `matches`
--     are dropped. New policies expose SELECT (so realtime
--     subscriptions keep working) and, on `calls`, UPDATE for
--     participants (so `CallSessionRepository.end()` and similar
--     in-flight updates keep working). INSERT is no longer
--     reachable via PostgREST — only via SECURITY DEFINER.
--   - v2 matching path (`mm_find_match` + `mm_accept_match`) is
--     unaffected : those RPCs are already SECURITY DEFINER and
--     bypass RLS by design.
--
-- Backward compatibility :
--   - Grandfather accounts pass `create_call_for_discover()`'s
--     identity check (`identity_verified=true AND age_verified=
--     true`) just like commit 1.
--   - Existing `calls` and `matches` rows are untouched.
--
-- Defense-in-depth :
--   - A UNIQUE INDEX on (LEAST(caller,callee), GREATEST) WHERE
--     status IN ('waiting','live') prevents duplicate active
--     calls per pair, even if a future bug re-opens a write path.
--
-- Rollback :
--   - Drop the two new RPCs.
--   - Drop the new SELECT-only / SELECT+UPDATE policies.
--   - Re-create `calls_all_participant` and `matches_all_participant`
--     as FOR ALL (the original 20260513120100 / 20260514130000
--     / 20260517130000 bodies are unchanged).
-- =============================================================================

-- ── 1. Defense-in-depth : UNIQUE active call per ordered pair ──
--
-- A user cannot have two concurrent active calls with the same peer.
-- The index uses LEAST/GREATEST so the pair is unordered (matches
-- the convention used by mm_find_match for match_history). Catches
-- a class of attack we haven't enumerated explicitly : even if a
-- future RPC bug reopens a direct write path, a spammer can't
-- create 100 simultaneous calls against the same victim.
CREATE UNIQUE INDEX IF NOT EXISTS idx_calls_unique_active_pair
  ON public.calls (
    LEAST(caller_id, callee_id),
    GREATEST(caller_id, callee_id)
  )
  WHERE status IN ('waiting', 'live');

-- ── 2. RPC : create_call_for_discover ──────────────────────────
--
-- Single supported way for a client to create a Discover-driven
-- (= weekly-suggestion-driven) call. Validates :
--   * caller is authenticated
--   * caller != peer
--   * caller is identity-verified (lenient, includes grandfather)
--   * no current waiting/live call for either side
--   * no mutual block
--
-- Generates the call_id internally and writes channel_name in the
-- same INSERT so the legacy two-step pattern from
-- `CallSessionRepository.open()` is gone : one round-trip, no
-- transient row with NULL channel_name.
CREATE OR REPLACE FUNCTION public.create_call_for_discover(p_peer_id UUID)
RETURNS public.calls
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_self   UUID := auth.uid();
    v_id     UUID := gen_random_uuid();
    v_row    public.calls;
BEGIN
    IF v_self IS NULL THEN
        RAISE EXCEPTION 'unauthorized' USING ERRCODE = '28000';
    END IF;
    IF p_peer_id IS NULL OR p_peer_id = v_self THEN
        RAISE EXCEPTION 'invalid_peer' USING ERRCODE = '22023';
    END IF;

    -- Identity gate (lenient, same shape as mm_join_queue post-V1-hardening)
    IF NOT EXISTS (
        SELECT 1 FROM public.profiles
         WHERE id = v_self
           AND identity_verified = true
           AND age_verified      = true
    ) THEN
        RAISE EXCEPTION 'identity_required' USING ERRCODE = '42501';
    END IF;

    -- Both sides must be allowed in matching surfaces.
    IF NOT EXISTS (
        SELECT 1 FROM public.profiles
         WHERE id = v_self
           AND is_banned = false
           AND moderation_status = 'active'
    ) THEN
        RAISE EXCEPTION 'profile_unavailable' USING ERRCODE = '42704';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM public.profiles
         WHERE id = p_peer_id
           AND is_banned = false
           AND moderation_status = 'active'
    ) THEN
        RAISE EXCEPTION 'peer_unavailable' USING ERRCODE = '42704';
    END IF;

    -- Mutual-block check (bilateral, like mm_find_match).
    IF EXISTS (
        SELECT 1 FROM public.blocked_users
         WHERE (user_id = v_self     AND blocked_user_id = p_peer_id)
            OR (user_id = p_peer_id  AND blocked_user_id = v_self)
    ) THEN
        RAISE EXCEPTION 'blocked' USING ERRCODE = '42501';
    END IF;

    -- No concurrent active call for either side. The UNIQUE INDEX
    -- created above is the hard guarantee ; this early check just
    -- yields a clean error code instead of a 23505 unique
    -- violation.
    IF EXISTS (
        SELECT 1 FROM public.calls
         WHERE status IN ('waiting','live')
           AND (caller_id IN (v_self, p_peer_id)
                OR callee_id IN (v_self, p_peer_id))
    ) THEN
        RAISE EXCEPTION 'already_in_call' USING ERRCODE = '23P01';
    END IF;

    INSERT INTO public.calls
        (id, caller_id, callee_id, status, channel_name, started_at,
         room_expires_at)
    VALUES
        (v_id, v_self, p_peer_id, 'live', 'dn_' || v_id::text, now(),
         -- 5 min 30 s : matches commit 2's go-live cap.
         now() + interval '5 minutes 30 seconds')
    RETURNING * INTO v_row;

    RETURN v_row;
END $$;

REVOKE ALL    ON FUNCTION public.create_call_for_discover(UUID) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.create_call_for_discover(UUID) TO authenticated;

COMMENT ON FUNCTION public.create_call_for_discover(UUID) IS
  'Discover-driven call creation. The only path authenticated '
  'clients have to create a new calls row : v2 matching uses '
  'mm_find_match/mm_accept_match (also SECURITY DEFINER) and '
  'direct INSERT on `calls` is blocked by RLS post-commit-4.';

-- ── 3. RPC : create_match_if_mutual ────────────────────────────
--
-- Single supported way for a client to flip a call into a mutual
-- match. Validates :
--   * caller is one of the call participants ;
--   * BOTH participants have a reveals row with decision='match'
--     on this call_id (the only valid source of "we mutually
--     liked each other") ;
--   * compatibility_score, when provided, is in 0-100 (caller-
--     supplied for cosmetics only ; the trust gate is mutual
--     reveal, not the score).
--
-- Idempotent on the (user_a_id, user_b_id) UNIQUE constraint.
CREATE OR REPLACE FUNCTION public.create_match_if_mutual(
    p_call_id              UUID,
    p_compatibility_score  INT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_self      UUID := auth.uid();
    v_caller    UUID;
    v_callee    UUID;
    v_a         UUID;
    v_b         UUID;
    v_match_id  UUID;
    v_mutual    BOOLEAN;
    v_score     INT;
BEGIN
    IF v_self IS NULL THEN
        RAISE EXCEPTION 'unauthorized' USING ERRCODE = '28000';
    END IF;

    SELECT caller_id, callee_id
      INTO v_caller, v_callee
      FROM public.calls
     WHERE id = p_call_id;
    IF v_caller IS NULL THEN
        RAISE EXCEPTION 'call_not_found' USING ERRCODE = '42704';
    END IF;
    IF v_self NOT IN (v_caller, v_callee) THEN
        RAISE EXCEPTION 'not_a_participant' USING ERRCODE = '42501';
    END IF;

    -- Mutual reveal check : both peers must have decision='match'
    -- on this call. Reveals table is write-protected to the peer's
    -- own row, so this count cannot be spoofed.
    SELECT COUNT(DISTINCT user_id) = 2
      INTO v_mutual
      FROM public.reveals
     WHERE call_id  = p_call_id
       AND decision = 'match'
       AND user_id IN (v_caller, v_callee);
    IF NOT v_mutual THEN
        RAISE EXCEPTION 'no_mutual_reveal' USING ERRCODE = '23P01';
    END IF;

    -- Clamp the client-supplied score ; null becomes 75 (the
    -- legacy default in the Dart MockDiscoverRepository).
    v_score := GREATEST(0, LEAST(100, COALESCE(p_compatibility_score, 75)));

    v_a := LEAST(v_caller, v_callee);
    v_b := GREATEST(v_caller, v_callee);

    INSERT INTO public.matches (user_a_id, user_b_id, compatibility_score,
                                call_id, status)
    VALUES (v_a, v_b, v_score, p_call_id, 'new')
    ON CONFLICT (user_a_id, user_b_id) DO UPDATE
        SET call_id = EXCLUDED.call_id,
            status  = CASE
                WHEN public.matches.status = 'archived' THEN 'archived'
                ELSE 'new'
            END
    RETURNING id INTO v_match_id;

    RETURN v_match_id;
END $$;

REVOKE ALL    ON FUNCTION public.create_match_if_mutual(UUID, INT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.create_match_if_mutual(UUID, INT) TO authenticated;

COMMENT ON FUNCTION public.create_match_if_mutual(UUID, INT) IS
  'Post-reveal match creation. The only path authenticated clients '
  'have to insert into `matches`. Verifies both peers have a '
  'reveals.decision=match row on the same call_id ; raises '
  'no_mutual_reveal otherwise.';

-- ── 4. Lock direct INSERT/DELETE on `calls` ────────────────────
DROP POLICY IF EXISTS "calls_all_participant" ON public.calls;

CREATE POLICY "calls_select_participant" ON public.calls
  FOR SELECT TO authenticated
  USING (auth.uid() IN (caller_id, callee_id));

-- Participants must still be able to UPDATE (status='ended',
-- ended_by, etc.) — the in-flight call_screen flow depends on it.
-- DELETE remains forbidden ; INSERT is unreachable via PostgREST
-- since no policy permits it.
CREATE POLICY "calls_update_participant" ON public.calls
  FOR UPDATE TO authenticated
  USING (auth.uid() IN (caller_id, callee_id))
  WITH CHECK (auth.uid() IN (caller_id, callee_id));

-- ── 5. Lock direct write on `matches` ──────────────────────────
DROP POLICY IF EXISTS "matches_all_participant" ON public.matches;

CREATE POLICY "matches_select_participant" ON public.matches
  FOR SELECT TO authenticated
  USING (auth.uid() IN (user_a_id, user_b_id));

-- No INSERT, no UPDATE, no DELETE policy. Writes flow exclusively
-- through `create_match_if_mutual()` (SECURITY DEFINER) or the
-- service role (delete-account cascade, admin tooling).

-- =============================================================================
-- After this migration applies :
--
--   - `INSERT INTO calls VALUES (...)` via PostgREST → 42501 RLS denial.
--   - `INSERT INTO matches VALUES (...)` via PostgREST → 42501 RLS denial.
--   - Discover flow : Dart calls `create_call_for_discover(peer_id)`.
--   - Reveal flow   : Dart calls `create_match_if_mutual(call_id, score)`.
--   - v2 matching flow (queue → find → accept) : unchanged.
--   - Realtime streams (.from('calls').stream(), .from('matches').stream()) :
--     unchanged, the SELECT policies preserve subscribability.
--   - Direct UPDATE on calls (e.g. end='ended', caller_ready=true via
--     mark_call_ready RPC fallback) : unchanged.
-- =============================================================================
