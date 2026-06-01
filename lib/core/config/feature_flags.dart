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

  /// Activates the Didit identity-verification gate on the Find-date
  /// CTA (Phase 5 of the Didit rollout).
  ///
  /// **Default ON** — diverges from every other flag in this file on
  /// purpose. Identity verification is a legal / compliance gate
  /// (18+ + face match + liveness) and shipping it dormant defeats
  /// the point. Flip OFF only as a fuse if Phase 2's Didit webhook
  /// payload paths turn out to be wrong on real sandbox traffic and
  /// the gate would deadlock new signups.
  ///
  /// Override in `.env`:
  ///
  ///     IDENTITY_GATE=false    (also accepts '0' or 'no')
  ///
  /// When OFF, the three Phase 5 surfaces hide together — gate,
  /// Profile banner, Settings tile — so the user sees zero hint of
  /// the feature. The dormant Phase 4 surface (`/identity` route) is
  /// still reachable via debug entry, just not advertised.
  static bool get requireIdentityVerification {
    final raw = (dotenv.env['IDENTITY_GATE'] ?? '').trim().toLowerCase();
    // Default ON — only the literal strings 'false' / '0' / 'no'
    // disable. Missing key, empty string, or any other value keeps
    // the gate active.
    return raw != 'false' && raw != '0' && raw != 'no';
  }

  /// Internal — reads `.env` value, accepts `true` / `1` / `yes`
  /// (case-insensitive). Anything else returns `false`. Mirrors the
  /// helper in [Env] so a future caller can read either class through
  /// the same boolean semantics.
  static bool _truthy(String key) {
    final raw = (dotenv.env[key] ?? '').trim().toLowerCase();
    return raw == 'true' || raw == '1' || raw == 'yes';
  }
}
