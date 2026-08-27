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
  static const int _wIntentions = 26;
  static const int _wInterests = 22;
  static const int _wDistance = 18;
  static const int _wAge = 12;
  static const int _wAvailability = 8;

  /// Drinking, smoking, education. Ordinary personal data: it weighs as soon
  /// as both sides have answered, with no separate opt-in, because being
  /// brought closer to a non-smoker is not a decision about who someone is.
  static const int _wLifestyle = 8;

  /// Origins and religion. Article 9 data, so this weight applies ONLY when
  /// both people explicitly asked to be matched on it. Declining costs
  /// nothing: the axis drops out and the remaining weights are rescaled to
  /// 100, exactly as an unknown distance already is.
  static const int _wAffinity = 6;

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

    // Both background axes are optional in the same sense distance already
    // was: absent means "does not apply", never "scores zero". A zero would
    // quietly punish the people who declined to answer, which is the one
    // thing a consent-based axis must never do.
    final lifestyle = _scoreLifestyle(a, b);
    final affinity = _scoreAffinity(a, b);

    final breakdown = <String, int>{
      'intentions': _scoreIntentions(a, b),
      'interests': _scoreInterests(a, b),
      'availability': _scoreAvailability(a, b),
      'age': _scoreAge(a, b),
      if (distanceKm != null) 'distance': _scoreDistance(a, b, distanceKm),
      if (lifestyle != null) 'lifestyle': lifestyle,
      if (affinity != null) 'affinity': affinity,
    };

    var applied = _wIntentions + _wInterests + _wAvailability + _wAge;
    if (distanceKm != null) applied += _wDistance;
    if (lifestyle != null) applied += _wLifestyle;
    if (affinity != null) applied += _wAffinity;

    // Rescale the axes themselves, not just the total.
    //
    // The old code rounded a total and left the breakdown on the raw scale.
    // That was consistent only while every axis applied — which used to be
    // the normal case and, with two optional background axes, no longer is.
    // Scaling the parts and summing them makes "the breakdown adds up to the
    // percentage" true by construction rather than by luck, so no reader has
    // to know which axes happened to apply.
    final scaled = applied == 100
        ? breakdown
        : breakdown.map(
            (axis, points) =>
                MapEntry(axis, (points * 100 / applied).round()),
          );
    final total = scaled.values.fold<int>(0, (sum, v) => sum + v);

    return MatchScore(
      percentage: total.clamp(0, 100),
      breakdown: Map.unmodifiable(scaled),
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

  /// Drinking, smoking and education, averaged over the fields BOTH sides
  /// answered. Null when they share no answered field — the axis then drops
  /// out of the denominator instead of scoring zero.
  int? _scoreLifestyle(UserProfile a, UserProfile b) {
    final parts = <double>[
      if (a.drinking != null && b.drinking != null)
        _ordinalCloseness(a.drinking!.index, b.drinking!.index,
            Drinking.values.length),
      if (a.smoking != null && b.smoking != null)
        _ordinalCloseness(
            a.smoking!.index, b.smoking!.index, Smoking.values.length),
      if (a.education != null && b.education != null)
        _educationCloseness(a.education!, b.education!),
    ];
    if (parts.isEmpty) return null;
    final avg = parts.reduce((x, y) => x + y) / parts.length;
    return (_wLifestyle * avg).round();
  }

  /// Origins and religion — the article 9 axis.
  ///
  /// Gated on BOTH sides having explicitly consented to be matched on that
  /// field. One-sided consent is not enough: weighing someone's religion
  /// because the other person cares would process their belief for a purpose
  /// they never agreed to.
  int? _scoreAffinity(UserProfile a, UserProfile b) {
    final parts = <double>[];

    if (a.matchOnOrigins &&
        b.matchOnOrigins &&
        a.origins.isNotEmpty &&
        b.origins.isNotEmpty) {
      final shared = a.origins.intersection(b.origins).length;
      final union = a.origins.union(b.origins).length;
      parts.add(union == 0 ? 0 : shared / union);
    }

    if (a.matchOnReligion &&
        b.matchOnReligion &&
        a.religion != null &&
        b.religion != null) {
      parts.add(a.religion == b.religion ? 1 : 0);
    }

    if (parts.isEmpty) return null;
    final avg = parts.reduce((x, y) => x + y) / parts.length;
    return (_wAffinity * avg).round();
  }

  /// 1 for the same answer, decaying with the distance between two ordered
  /// answers. "Never" and "often" are further apart than "never" and
  /// "socially", and the score should say so.
  double _ordinalCloseness(int i, int j, int levels) {
    if (levels <= 1) return 1;
    return 1 - (i - j).abs() / (levels - 1);
  }

  /// Education is only partly ordered — `other` sits outside the ladder, so
  /// it matches itself and nothing else rather than pretending to be a rung.
  double _educationCloseness(EducationLevel a, EducationLevel b) {
    if (a == b) return 1;
    if (a == EducationLevel.other || b == EducationLevel.other) return 0;
    return _ordinalCloseness(a.index, b.index, EducationLevel.values.length - 1);
  }

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
