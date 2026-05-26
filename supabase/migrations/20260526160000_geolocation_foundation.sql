-- =============================================================================
-- DateNow — geolocation foundation (Phase 1.1)
--
-- Adds real lat/lon storage to `profiles` so the matching pipeline can
-- compute true distance via PostGIS instead of the current hardcoded
-- 10 km value. This migration ONLY puts the foundation in place —
-- the live matching code keeps using its old constant until Phase 1.5
-- (cutover to find_best_live_candidate).
--
-- Privacy: lat/lon are personal data. Stored as PostGIS geography so
-- ST_DistanceSphere is fast (GIST-indexed). Distance is exposed to the
-- other user only at the meter level via the future find_best_live_*
-- RPCs — coordinates themselves are never returned to other clients.
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS postgis;

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS location              GEOGRAPHY(Point, 4326),
  ADD COLUMN IF NOT EXISTS location_updated_at   TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS location_accuracy_m   INTEGER;

CREATE INDEX IF NOT EXISTS profiles_location_gist
  ON public.profiles USING GIST (location)
  WHERE location IS NOT NULL;

-- -----------------------------------------------------------------------------
-- RPC: update_my_location(p_lat, p_lng, p_accuracy_m)
--
-- Self-only write path for the user's current coordinates. Wraps the
-- UPDATE in a SECURITY DEFINER function so we can:
--   * validate the inputs server-side (avoid garbage coords),
--   * rate-limit if needed in the future,
--   * audit calls through the function log (Supabase Functions tab).
--
-- The RPC writes to `auth.uid()`'s own row only. There is no overload
-- to write on someone else's behalf.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.update_my_location(
  p_lat        DOUBLE PRECISION,
  p_lng        DOUBLE PRECISION,
  p_accuracy_m INTEGER DEFAULT NULL
) RETURNS public.profiles
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me UUID := auth.uid();
  out_row public.profiles;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'auth.uid() is null — call requires an authenticated session'
      USING ERRCODE = '28000';
  END IF;

  -- WGS84 sanity checks. Reject obviously bad inputs rather than
  -- writing garbage that would silently break distance queries later.
  IF p_lat IS NULL OR p_lng IS NULL THEN
    RAISE EXCEPTION 'lat/lng must both be provided' USING ERRCODE = '22023';
  END IF;
  IF p_lat < -90 OR p_lat > 90 THEN
    RAISE EXCEPTION 'lat out of range [-90, 90]: %', p_lat
      USING ERRCODE = '22023';
  END IF;
  IF p_lng < -180 OR p_lng > 180 THEN
    RAISE EXCEPTION 'lng out of range [-180, 180]: %', p_lng
      USING ERRCODE = '22023';
  END IF;
  IF p_accuracy_m IS NOT NULL AND p_accuracy_m < 0 THEN
    RAISE EXCEPTION 'accuracy must be >= 0 meters' USING ERRCODE = '22023';
  END IF;

  UPDATE public.profiles
     SET location            = ST_MakePoint(p_lng, p_lat)::geography,
         location_updated_at = now(),
         location_accuracy_m = p_accuracy_m
   WHERE id = me
   RETURNING * INTO out_row;

  RETURN out_row;
END;
$$;

REVOKE ALL ON FUNCTION public.update_my_location(
  DOUBLE PRECISION, DOUBLE PRECISION, INTEGER
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.update_my_location(
  DOUBLE PRECISION, DOUBLE PRECISION, INTEGER
) TO authenticated;
