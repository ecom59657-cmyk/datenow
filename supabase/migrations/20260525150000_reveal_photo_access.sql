-- =============================================================================
-- DateNow — peer photo access during the mutual-reveal window
--
-- The pre-existing policies (`user_photos_select_matched`,
-- `profile_photos_select_matched`) only authorise reading a peer's
-- photo metadata + bytes when a row exists in `public.matches`.
--
-- After the reveal flow was made bilateral, the match row is only
-- created AFTER the user taps "Matcher" on the mutual-reveal screen.
-- But the user needs to SEE the photo to decide whether to tap
-- "Matcher" — chicken-and-egg.
--
-- This migration adds two parallel policies that open access during
-- the mutual-reveal window: when both peers of a shared call have
-- `reveals.revealed = true`, each can read the other's photo metadata
-- and download the bytes. After tapping "Matcher" the original
-- `_matched` policy takes over (idempotent — both policies grant
-- access, RLS short-circuits on the first match).
--
-- Refusing pass-after-reveal: if either peer flips `revealed` to false
-- the EXISTS clause stops matching, so the photo immediately becomes
-- unreadable again.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. user_photos — peers in a mutual-reveal call can read the metadata
-- -----------------------------------------------------------------------------
DROP POLICY IF EXISTS "user_photos_select_mutual_reveal"
  ON public.user_photos;
CREATE POLICY "user_photos_select_mutual_reveal"
  ON public.user_photos FOR SELECT
  USING (
    EXISTS (
      SELECT 1
      FROM public.reveals me
      JOIN public.reveals peer
        ON peer.call_id = me.call_id
       AND peer.user_id <> me.user_id
      WHERE me.user_id = auth.uid()
        AND me.revealed = true
        AND peer.revealed = true
        AND peer.user_id = user_photos.user_id
    )
  );

-- -----------------------------------------------------------------------------
-- 2. storage.objects (profile-photos bucket) — same gate on the bytes
-- -----------------------------------------------------------------------------
DROP POLICY IF EXISTS "profile_photos_select_mutual_reveal"
  ON storage.objects;
CREATE POLICY "profile_photos_select_mutual_reveal"
  ON storage.objects FOR SELECT
  USING (
    bucket_id = 'profile-photos'
    AND EXISTS (
      SELECT 1
      FROM public.reveals me
      JOIN public.reveals peer
        ON peer.call_id = me.call_id
       AND peer.user_id <> me.user_id
      WHERE me.user_id = auth.uid()
        AND me.revealed = true
        AND peer.revealed = true
        AND peer.user_id::text = (storage.foldername(name))[1]
    )
  );
