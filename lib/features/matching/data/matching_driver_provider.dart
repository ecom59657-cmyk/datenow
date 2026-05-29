import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/feature_flags.dart';
import '../../../core/services/supabase_service.dart';
import 'fallback_matching_driver.dart';
import 'legacy_matching_driver.dart';
import 'matching_driver.dart';
import 'matchmaking_repository.dart';
import 'v2_matching_driver.dart';

/// Returns the active [MatchingDriver] for the current Riverpod scope.
///
/// Selection rules:
///
///   * `FeatureFlags.useMatchingV2 = false` (the default, dormant
///     state)  → [LegacyMatchingDriver] directly. No V2 code reached
///     at runtime, behaviour strictly identical to the pre-driver
///     commit.
///
///   * `FeatureFlags.useMatchingV2 = true` (activation builds only)
///     → [FallbackMatchingDriver] wrapping a [V2MatchingDriver]
///     primary and a [LegacyMatchingDriver] fallback. Any V2 method
///     throw is transparently retried on V1.
///
///   * Supabase unavailable (offline boot, missing env) →  `null`,
///     same contract as the underlying [matchmakingRepositoryProvider].
final matchingDriverProvider = Provider<MatchingDriver?>((ref) {
  final repo = ref.watch(matchmakingRepositoryProvider);
  if (repo == null) return null;
  final legacy = LegacyMatchingDriver(repo);
  if (!FeatureFlags.useMatchingV2) return legacy;
  final v2 = V2MatchingDriver(ref.watch(supabaseClientProvider));
  return FallbackMatchingDriver(primary: v2, fallback: legacy);
});
