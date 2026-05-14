-- =============================================================================
-- DateNow — Storage bucket for profile photos
--
-- The bucket is private. Clients receive a signed URL via the Storage API
-- only after the matching policies below permit access.
--
-- Convention: object paths are `<user_id>/<file_name>` so the owner check
-- uses `storage.foldername(name)[1]`.
-- =============================================================================

INSERT INTO storage.buckets (id, name, public)
VALUES ('profile-photos', 'profile-photos', false)
ON CONFLICT (id) DO NOTHING;

-- Owner can do anything with their own folder.
CREATE POLICY "profile_photos_owner_all"
  ON storage.objects FOR ALL
  USING (
    bucket_id = 'profile-photos'
    AND (storage.foldername(name))[1] = auth.uid()::text
  )
  WITH CHECK (
    bucket_id = 'profile-photos'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );

-- A matched peer may SELECT (download) — never UPDATE/DELETE.
CREATE POLICY "profile_photos_select_matched"
  ON storage.objects FOR SELECT
  USING (
    bucket_id = 'profile-photos'
    AND EXISTS (
      SELECT 1
      FROM public.matches m
      WHERE (
              m.user_a_id = auth.uid()
              AND m.user_b_id::text = (storage.foldername(name))[1]
            )
         OR (
              m.user_b_id = auth.uid()
              AND m.user_a_id::text = (storage.foldername(name))[1]
            )
    )
  );
