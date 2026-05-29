import 'package:flutter_dotenv/flutter_dotenv.dart';

/// Behavioural feature flags read from `.env` at bootstrap.
///
/// **Strictly OFF by default.** Each getter is a pure dotenv lookup —
/// adding a flag here never changes runtime behaviour unless the
/// matching `.env` key is explicitly set to a truthy value.
///
/// Lives next to [Env] (which exposes secrets / URLs) but kept in a
/// separate class so the intent is unambiguous: anything reachable from
/// `FeatureFlags.*` is a runtime *switch*, never a credential.
///
/// Truthy values (case-insensitive): `true`, `1`, `yes`. Everything
/// else, including missing keys, returns `false`.
class FeatureFlags {
  const FeatureFlags._();

  /// Activates the V2 matching engine — i.e. the
  /// `lib/features/matching/data/v2_matching_driver.dart` Edge-Function
  /// driver wrapped in [FallbackMatchingDriver] so any V2 failure falls
  /// back to the legacy V1 path automatically.
  ///
  /// **Default OFF.** When `false`, `matchingDriverProvider` returns
  /// [LegacyMatchingDriver] directly — zero V2 code reachable at
  /// runtime, behaviour strictly identical to the pre-flag commit.
  ///
  /// Flip via `.env`:
  ///
  ///     MATCHING_V2=true
  ///
  /// Production rollout protocol (per matching plan):
  ///   1. `MATCHING_V2=false` (default) — ship the dormant driver,
  ///      verify zero behavioural regression on V1.
  ///   2. Internal TestFlight build with `MATCHING_V2=true` — exercise
  ///      the full V2 flow on the test cohort, watch `[MATCHING V2]`
  ///      logs + `find-match` Edge Function metrics.
  ///   3. Gradual rollout (env-by-env, or per-user remote flag) once
  ///      S1 / S2 / S3 are validated end-to-end on V2.
  static bool get useMatchingV2 => _truthy('MATCHING_V2');

  /// Internal — reads `.env` value, accepts `true` / `1` / `yes`
  /// (case-insensitive). Anything else returns `false`. Mirrors the
  /// helper in [Env] so a future caller can read either class through
  /// the same boolean semantics.
  static bool _truthy(String key) {
    final raw = (dotenv.env[key] ?? '').trim().toLowerCase();
    return raw == 'true' || raw == '1' || raw == 'yes';
  }
}
