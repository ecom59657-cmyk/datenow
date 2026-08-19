import 'package:datenow/features/matching/data/matching_service.dart';
import 'package:datenow/features/matching/domain/match_score.dart';
import 'package:datenow/features/profile_setup/domain/enums.dart';
import 'package:datenow/features/profile_setup/domain/interest.dart';
import 'package:datenow/features/profile_setup/domain/user_profile.dart';
import 'package:flutter_test/flutter_test.dart';

/// Builds a fully-formed profile with sensible defaults so each test only
/// has to spell out what it changes.
UserProfile _profile({
  required String id,
  required Gender gender,
  required Set<Gender> seekingGenders,
  int age = 28,
  Set<Intention> intentions = const {Intention.feeling, Intention.serious},
  Set<Interest> interests = const {
    Interest.music,
    Interest.travel,
    Interest.foodie,
    Interest.films,
  },
  Availability availability = Availability.immediate,
  Orientation? orientation = Orientation.straight,
  int seekingAgeMin = 22,
  int seekingAgeMax = 36,
  int maxDistanceKm = 50,
}) {
  final today = DateTime.now();
  return UserProfile(
    userId: id,
    firstName: id,
    birthDate: DateTime(today.year - age, today.month, today.day),
    gender: gender,
    orientation: orientation,
    seekingGenders: seekingGenders,
    seekingAgeMin: seekingAgeMin,
    seekingAgeMax: seekingAgeMax,
    maxDistanceKm: maxDistanceKm,
    intentions: intentions,
    interests: interests,
    availability: availability,
  );
}

void main() {
  const service = MatchingService();

  group('MatchingService hard gates', () {
    test('rejects when reciprocal gender preference is missing', () {
      final a = _profile(
        id: 'a',
        gender: Gender.female,
        seekingGenders: {Gender.male},
      );
      // b is a man, b doesn't seek women → reciprocity fails.
      final b = _profile(
        id: 'b',
        gender: Gender.male,
        seekingGenders: {Gender.male},
      );
      expect(service.calculateCompatibility(a, b, distanceKm: 5), isNull);
    });

    test('rejects when age falls outside the other side preferred range', () {
      final a = _profile(
        id: 'a',
        gender: Gender.female,
        seekingGenders: {Gender.male},
        age: 30,
        seekingAgeMin: 25,
        seekingAgeMax: 40,
      );
      final b = _profile(
        id: 'b',
        gender: Gender.male,
        seekingGenders: {Gender.female},
        age: 50, // outside a's 25..40 window
      );
      expect(service.calculateCompatibility(a, b, distanceKm: 5), isNull);
    });

    test('rejects when distance exceeds the lower of the two caps', () {
      final a = _profile(
        id: 'a',
        gender: Gender.female,
        seekingGenders: {Gender.male},
        maxDistanceKm: 10,
      );
      final b = _profile(
        id: 'b',
        gender: Gender.male,
        seekingGenders: {Gender.female},
        maxDistanceKm: 80,
      );
      expect(service.calculateCompatibility(a, b, distanceKm: 50), isNull);
    });
  });

  group('MatchingService intention gate', () {
    UserProfile withIntentions(String id, Gender g, Set<Intention> i) =>
        _profile(
          id: id,
          gender: g,
          seekingGenders: {g == Gender.male ? Gender.female : Gender.male},
          intentions: i,
        );

    test('exclusively serious never meets exclusively casual', () {
      final a = withIntentions('a', Gender.male, {Intention.serious});
      final b = withIntentions('b', Gender.female, {Intention.casual});
      expect(service.calculateCompatibility(a, b, distanceKm: 5), isNull);
      // Symmetric: the gate must not depend on argument order.
      expect(service.calculateCompatibility(b, a, distanceKm: 5), isNull);
    });

    test('an overlap anywhere keeps the pair eligible', () {
      final a = withIntentions(
        'a',
        Gender.male,
        {Intention.serious, Intention.feeling},
      );
      final b = withIntentions(
        'b',
        Gender.female,
        {Intention.casual, Intention.feeling},
      );
      expect(service.calculateCompatibility(a, b, distanceKm: 5), isNotNull);
    });

    test('an undeclared side is never blocked', () {
      final a = withIntentions('a', Gender.male, {Intention.serious});
      final b = withIntentions('b', Gender.female, const {});
      expect(service.calculateCompatibility(a, b, distanceKm: 5), isNotNull);
    });

    test('only the serious/casual pair clashes, not talk or feeling', () {
      final a = withIntentions('a', Gender.male, {Intention.serious});
      for (final other in [Intention.talk, Intention.feeling]) {
        final b = withIntentions('b', Gender.female, {other});
        expect(
          service.calculateCompatibility(a, b, distanceKm: 5),
          isNotNull,
          reason: 'serious vs ${other.name} must stay possible',
        );
      }
    });
  });

  group('MatchingService scoring', () {
    test('two near-identical profiles score very high', () {
      final shared = {Gender.female};
      final a = _profile(
        id: 'a',
        gender: Gender.male,
        seekingGenders: shared,
      );
      final b = _profile(
        id: 'b',
        gender: Gender.female,
        seekingGenders: {Gender.male},
      );
      final score = service.calculateCompatibility(a, b, distanceKm: 2);
      expect(score, isNotNull);
      expect(score!.percentage, greaterThanOrEqualTo(90));
      expect(score.band, MatchBand.veryHigh);
    });

    test('two compatible but partially-overlapping profiles land in the middle bands',
        () {
      final a = _profile(
        id: 'a',
        gender: Gender.male,
        seekingGenders: {Gender.female},
        interests: {Interest.music, Interest.travel, Interest.foodie},
        // Overlapping intentions: this case is about the soft weighting,
        // not the clash gate — `{serious}` vs `{casual}` is now rejected
        // outright and is covered on its own below.
        intentions: {Intention.serious, Intention.feeling},
        availability: Availability.immediate,
      );
      final b = _profile(
        id: 'b',
        gender: Gender.female,
        seekingGenders: {Gender.male},
        interests: {Interest.fitness, Interest.dance, Interest.music},
        intentions: {Intention.casual, Intention.feeling},
        availability: Availability.sometime,
      );
      final score = service.calculateCompatibility(a, b, distanceKm: 30);
      expect(score, isNotNull);
      expect(score!.percentage, inInclusiveRange(20, 74));
      expect(score.band, isNot(MatchBand.veryHigh));
    });

    test('the axes still sum to 100 — no weight lost with orientation', () {
      // Maximal on every axis: identical intentions and interests, both
      // immediate, distance 0, and ages sitting exactly at the centre of
      // the 22-36 window (29) — `_ageFit` rewards the centre, so any other
      // age costs a point or two and would hide a weight that went
      // missing. If the remaining weights no longer total 100, this drifts
      // off the ceiling.
      final a = _profile(
        id: 'a',
        age: 29,
        gender: Gender.male,
        seekingGenders: {Gender.female},
        interests: {Interest.music, Interest.travel},
        intentions: {Intention.serious},
        availability: Availability.immediate,
      );
      final b = _profile(
        id: 'b',
        age: 29,
        gender: Gender.female,
        seekingGenders: {Gender.male},
        interests: {Interest.music, Interest.travel},
        intentions: {Intention.serious},
        availability: Availability.immediate,
      );
      final score = service.calculateCompatibility(a, b, distanceKm: 0);
      expect(score, isNotNull);
      expect(score!.percentage, 100);
      // The orientation key is gone for good — a stale reader summing the
      // breakdown must not find it.
      expect(score.breakdown.containsKey('orientation'), isFalse);
      expect(score.breakdown.keys, hasLength(5));
    });

    test('percentage is clamped to 0..100 and breakdown sums to it', () {
      final a = _profile(
        id: 'a',
        gender: Gender.female,
        seekingGenders: {Gender.male},
      );
      final b = _profile(
        id: 'b',
        gender: Gender.male,
        seekingGenders: {Gender.female},
      );
      final score = service.calculateCompatibility(a, b, distanceKm: 8);
      expect(score, isNotNull);
      expect(score!.percentage, inInclusiveRange(0, 100));
      final sum =
          score.breakdown.values.fold<int>(0, (acc, v) => acc + v);
      // Sum can differ by 1 from percentage due to clamp + rounding edge.
      expect((sum - score.percentage).abs(), lessThanOrEqualTo(1));
    });
  });
}
