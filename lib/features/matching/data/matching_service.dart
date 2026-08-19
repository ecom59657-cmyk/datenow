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
  //
  // The orientation axis is gone. It handed out its full weight to any pair
  // where both sides had merely *declared* an orientation — which is every
  // completed profile, since profile setup requires it. Fifteen of the
  // hundred points therefore discriminated nothing and inflated every score
  // by the same amount. Its weight goes where it actually separates people:
  // intentions first, then distance and age.
  static const int _wIntentions = 30;
  static const int _wInterests = 25;
  static const int _wDistance = 20;
  static const int _wAge = 15;
  static const int _wAvailability = 10;

  /// Computes the compatibility between [a] and [b] given their current
  /// geographic [distanceKm].
  ///
  /// Returns `null` when any hard gate fails — in that case the candidate
  /// must not be proposed at all, regardless of how high the soft score
  /// would have been.
  /// [distanceKm] is nullable, and null means *unknown* — not zero.
  ///
  /// It used to be required, and every caller synthesised it with
  /// `MockCandidateFactory.distanceFor`, which is `1 + random(maxDistanceKm)`.
  /// Two consequences, both measured rather than assumed:
  ///
  ///   * the same pair scored anywhere from 65 to 85 depending on the roll —
  ///     20 points, enough to cross from "Forte compatibilité" to "Très
  ///     compatible". Discover persists that number for a week, so the dice
  ///     stuck;
  ///   * the roll fed a hard gate too. It is drawn from *self's* radius and
  ///     compared against the *smaller* of the two, so a real candidate could
  ///     be dropped outright by chance.
  ///
  /// Passing 0 was worse than useless: `1 - 0/cap` is 1, so a distance nobody
  /// knew was awarded full marks.
  ///
  /// Unknown now removes the axis from the total and renormalises over the
  /// weights that did apply, so two candidates stay comparable on the same
  /// 0..100 scale whether or not their position is known. An unknown never
  /// rewards and never punishes.
  MatchScore? calculateCompatibility(
    UserProfile a,
    UserProfile b, {
    required int? distanceKm,
  }) {
    if (!_hardGatesPass(a, b, distanceKm: distanceKm)) return null;

    final breakdown = <String, int>{
      'intentions': _scoreIntentions(a, b),
      'interests': _scoreInterests(a, b),
      'availability': _scoreAvailability(a, b),
      'age': _scoreAge(a, b),
      if (distanceKm != null) 'distance': _scoreDistance(a, b, distanceKm),
    };

    const appliedWithoutDistance =
        _wIntentions + _wInterests + _wAvailability + _wAge;
    final applied = distanceKm == null
        ? appliedWithoutDistance
        : appliedWithoutDistance + _wDistance;

    final raw = breakdown.values.fold<int>(0, (sum, v) => sum + v);
    final total = applied == 100 ? raw : (raw * 100 / applied).round();

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
    required int? distanceKm,
  }) {
    // Reciprocal gender: each side must list the other's gender.
    if (a.gender == null || b.gender == null) return false;
    if (!a.seekingGenders.contains(b.gender)) return false;
    if (!b.seekingGenders.contains(a.gender)) return false;

    // Reciprocal age range.
    if (a.age == null || b.age == null) return false;
    if (b.age! < a.seekingAgeMin || b.age! > a.seekingAgeMax) return false;
    if (a.age! < b.seekingAgeMin || a.age! > b.seekingAgeMax) return false;

    // Distance: must be within both users' max-distance threshold — but
    // only when it is known. Rejecting on an unknown position would empty
    // the pool; rejecting on a synthesised one, which is what used to
    // happen, dropped real people at random.
    if (distanceKm != null) {
      final dCap = math.min(a.maxDistanceKm, b.maxDistanceKm);
      if (distanceKm > dCap) return false;
    }

    // Head-on clash of intentions. Five minutes of live video is too
    // expensive to spend on a serious/casual mismatch, and neither person
    // can leave gracefully once the call has started.
    if (!intentionsCompatible(a.intentions, b.intentions)) return false;

    return true;
  }

  /// Blocks only the unambiguous opposition: one side exclusively after
  /// something serious, the other exclusively after something casual.
  /// Everything else stays on the table — the soft weighting is there to
  /// rank those, and gating any wider would empty the pool at launch
  /// volume.
  static bool intentionsCompatible(Set<Intention> a, Set<Intention> b) {
    if (a.isEmpty || b.isEmpty) return true;
    if (a.intersection(b).isNotEmpty) return true;
    bool only(Set<Intention> s, Intention i) => s.length == 1 && s.first == i;
    final clash = (only(a, Intention.serious) && only(b, Intention.casual)) ||
        (only(a, Intention.casual) && only(b, Intention.serious));
    return !clash;
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
