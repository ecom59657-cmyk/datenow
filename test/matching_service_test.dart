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
        intentions: {Intention.serious},
        availability: Availability.immediate,
      );
      final b = _profile(
        id: 'b',
        gender: Gender.female,
        seekingGenders: {Gender.male},
        interests: {Interest.fitness, Interest.dance, Interest.music},
        intentions: {Intention.casual},
        availability: Availability.sometime,
      );
      final score = service.calculateCompatibility(a, b, distanceKm: 30);
      expect(score, isNotNull);
      expect(score!.percentage, inInclusiveRange(30, 79));
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
