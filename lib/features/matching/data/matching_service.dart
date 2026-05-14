import 'dart:math' as math;

import '../../profile_setup/domain/enums.dart';
import '../../profile_setup/domain/user_profile.dart';
import '../domain/match_score.dart';

/// Pure compatibility scoring — no I/O, no side effects. Splitting this out
/// from the repository lets us unit-test it in isolation and reuse the same
/// implementation for any backend (Supabase realtime, on-device cache, …).
class MatchingService {
  const MatchingService();

  // Soft-score weights. They must sum to 100.
  static const int _wIntentions = 25;
  static const int _wInterests = 25;
  static const int _wDistance = 15;
  static const int _wOrientation = 15;
  static const int _wAvailability = 10;
  static const int _wAge = 10;

  /// Computes the compatibility between [a] and [b] given their current
  /// geographic [distanceKm].
  ///
  /// Returns `null` when any hard gate fails — in that case the candidate
  /// must not be proposed at all, regardless of how high the soft score
  /// would have been.
  MatchScore? calculateCompatibility(
    UserProfile a,
    UserProfile b, {
    required int distanceKm,
  }) {
    if (!_hardGatesPass(a, b, distanceKm: distanceKm)) return null;

    final breakdown = <String, int>{
      'intentions': _scoreIntentions(a, b),
      'interests': _scoreInterests(a, b),
      'distance': _scoreDistance(a, b, distanceKm),
      'orientation': _scoreOrientation(a, b),
      'availability': _scoreAvailability(a, b),
      'age': _scoreAge(a, b),
    };

    final total = breakdown.values.fold<int>(0, (sum, v) => sum + v);
    return MatchScore(
      percentage: total.clamp(0, 100),
      breakdown: Map.unmodifiable(breakdown),
    );
  }

  // ---------------------------------------------------------------------
  // Hard gates — both profiles must accept each other on the basics.
  // ---------------------------------------------------------------------

  bool _hardGatesPass(
    UserProfile a,
    UserProfile b, {
    required int distanceKm,
  }) {
    // Reciprocal gender: each side must list the other's gender.
    if (a.gender == null || b.gender == null) return false;
    if (!a.seekingGenders.contains(b.gender)) return false;
    if (!b.seekingGenders.contains(a.gender)) return false;

    // Reciprocal age range.
    if (a.age == null || b.age == null) return false;
    if (b.age! < a.seekingAgeMin || b.age! > a.seekingAgeMax) return false;
    if (a.age! < b.seekingAgeMin || a.age! > b.seekingAgeMax) return false;

    // Distance: must be within both users' max-distance threshold.
    final dCap = math.min(a.maxDistanceKm, b.maxDistanceKm);
    if (distanceKm > dCap) return false;

    return true;
  }

  // ---------------------------------------------------------------------
  // Soft scoring axes — each returns `0..weight`.
  // ---------------------------------------------------------------------

  int _scoreIntentions(UserProfile a, UserProfile b) {
    return _weightedJaccard(a.intentions, b.intentions, _wIntentions);
  }

  int _scoreInterests(UserProfile a, UserProfile b) {
    return _weightedJaccard(a.interests, b.interests, _wInterests);
  }

  int _scoreDistance(UserProfile a, UserProfile b, int distanceKm) {
    final cap = math.min(a.maxDistanceKm, b.maxDistanceKm);
    if (cap <= 0) return 0;
    final ratio = (1 - distanceKm / cap).clamp(0.0, 1.0);
    return (_wDistance * ratio).round();
  }

  int _scoreAge(UserProfile a, UserProfile b) {
    // How well b.age sits inside a's preferred band — and vice versa. We
    // reward candidates near the centre of the requested window, not just
    // anywhere in it.
    final fitAtoB = _ageFit(b.age!, a.seekingAgeMin, a.seekingAgeMax);
    final fitBtoA = _ageFit(a.age!, b.seekingAgeMin, b.seekingAgeMax);
    final avg = (fitAtoB + fitBtoA) / 2;
    return (_wAge * avg).round();
  }

  double _ageFit(int age, int min, int max) {
    if (max <= min) return 1;
    final centre = (min + max) / 2;
    final halfSpan = (max - min) / 2;
    final distance = (age - centre).abs();
    return (1 - distance / halfSpan).clamp(0.0, 1.0);
  }

  int _scoreAvailability(UserProfile a, UserProfile b) {
    final av = a.availability;
    final bv = b.availability;
    if (av == null || bv == null) return 0;
    if (av == Availability.immediate && bv == Availability.immediate) {
      return _wAvailability;
    }
    if (av == bv) return (_wAvailability * 0.7).round();
    return (_wAvailability * 0.4).round();
  }

  int _scoreOrientation(UserProfile a, UserProfile b) {
    // For MVP we don't model orientation compatibility deeply — gender
    // reciprocity above already handles "who's attracted to whom" at a
    // functional level. We grant the points when both sides have declared
    // their orientation (better signal than missing data).
    if (a.orientation == null || b.orientation == null) return 0;
    return _wOrientation;
  }

  // ---------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------

  /// Jaccard similarity (|A∩B| / |A∪B|) scaled to [0..weight].
  int _weightedJaccard<T>(Set<T> a, Set<T> b, int weight) {
    final union = {...a, ...b};
    if (union.isEmpty) return 0;
    final inter = a.intersection(b);
    return (weight * inter.length / union.length).round();
  }
}
