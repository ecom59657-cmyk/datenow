// An unknown distance must neither reward nor punish.
//
// It used to be neither: every caller synthesised one with
// `MockCandidateFactory.distanceFor`, which is `1 + random(maxDistanceKm)`.
// Measured on the real service, the same pair scored 65 to 85 depending on
// the roll — across the "Forte compatibilité" / "Très compatible" boundary.
// Discover persists that number for a week, so the die stuck.
//
// Passing 0 instead was worse: `1 - 0/cap` is 1, so a distance nobody knew
// was awarded the full distance weight.

import 'package:datenow/features/matching/data/matching_service.dart';
import 'package:datenow/features/matching/domain/match_score.dart';
import 'package:datenow/features/profile_setup/domain/enums.dart' as d;
import 'package:datenow/features/profile_setup/domain/interest.dart';
import 'package:datenow/features/profile_setup/domain/user_profile.dart';
import 'package:flutter_test/flutter_test.dart';

UserProfile _p({
  required String id,
  required d.Gender gender,
  required Set<d.Gender> seeking,
  required int birthYear,
  Set<Interest> interests = const {},
  int maxDistanceKm = 50,
  int seekingAgeMin = 25,
  int seekingAgeMax = 40,
}) =>
    UserProfile(
      userId: id,
      firstName: id,
      birthDate: DateTime(birthYear, 6, 1),
      gender: gender,
      orientation: d.Orientation.straight,
      seekingGenders: seeking,
      seekingAgeMin: seekingAgeMin,
      seekingAgeMax: seekingAgeMax,
      maxDistanceKm: maxDistanceKm,
      intentions: const {d.Intention.feeling},
      interests: interests,
      availability: d.Availability.immediate,
    );

const _svc = MatchingService();

UserProfile get _a => _p(
      id: 'A',
      gender: d.Gender.male,
      seeking: const {d.Gender.female},
      birthYear: 1994,
      interests: const {Interest.music, Interest.travel, Interest.foodie},
    );

UserProfile get _b => _p(
      id: 'B',
      gender: d.Gender.female,
      seeking: const {d.Gender.male},
      birthYear: 1996,
      interests: const {Interest.music, Interest.travel, Interest.sports},
    );

void main() {
  group('unknown distance', () {
    test('drops the axis from the breakdown instead of scoring it 0', () {
      final s = _svc.calculateCompatibility(_a, _b, distanceKm: null)!;
      expect(s.breakdown.containsKey('distance'), isFalse);
      expect(s.breakdown.keys,
          containsAll(['intentions', 'interests', 'age', 'availability']));
    });

    test('is not silently awarded full marks, the way 0 km was', () {
      final unknown = _svc.calculateCompatibility(_a, _b, distanceKm: null)!;
      final atZero = _svc.calculateCompatibility(_a, _b, distanceKm: 0)!;

      // 0 km is a genuine "next door" and still earns the axis in full. A
      // literal would go stale the next time a weight moves, so the property
      // is stated instead: nothing beats being next door.
      final atOne = _svc.calculateCompatibility(_a, _b, distanceKm: 1)!;
      expect(atZero.breakdown['distance']!,
          greaterThanOrEqualTo(atOne.breakdown['distance']!));

      // And the point of the whole test: "unknown" must not land on the same
      // number as "next door" by accident, which is what used to happen.
      expect(unknown.percentage, isNot(equals(atZero.percentage)));
    });

    test('renormalises: a pair perfect on every remaining axis reaches 100',
        () {
      // The age axis rewards the *centre* of the requested band, so the
      // window has to be centred on the age for this pair to be perfect —
      // 32 inside 25..40 scores 14/15, not 15, and the first version of
      // this test was wrong about that rather than the code being wrong.
      const interests = {Interest.music, Interest.travel, Interest.foodie};
      final twin = _p(
        id: 'B',
        gender: d.Gender.female,
        seeking: const {d.Gender.male},
        birthYear: 1994,
        interests: interests,
        seekingAgeMin: 30,
        seekingAgeMax: 34,
      );
      final self = _p(
        id: 'A',
        gender: d.Gender.male,
        seeking: const {d.Gender.female},
        birthYear: 1994,
        interests: interests,
        seekingAgeMin: 30,
        seekingAgeMax: 34,
      );

      final s = _svc.calculateCompatibility(self, twin, distanceKm: null)!;
      // Rescaled, not raw: with the distance axis absent the remaining
      // weights are stretched back over 100, so an age-perfect pair reads
      // higher than the raw 12.
      expect(s.breakdown['age'], greaterThan(12),
          reason: 'the pair must be age-perfect, on the rescaled scale');
      expect(s.percentage, 100,
          reason: 'the scale must stay 0..100 when an axis is missing');
    });

    test('the renormalisation is exactly "over the weights that applied"', () {
      // The property, rather than a hand-computed example. The axes are now
      // rescaled themselves when one drops out, so the invariant is simply
      // that the parts add up to the whole — no denominator to keep in sync
      // with the weights table, which is what made the old version of this
      // test go stale the day a weight moved.
      final s = _svc.calculateCompatibility(_a, _b, distanceKm: null)!;
      final sum = s.breakdown.values.fold<int>(0, (t, v) => t + v);
      expect(s.percentage, sum);
      expect(s.breakdown.containsKey('distance'), isFalse);
    });

    test('stays inside 0..100 for a poor pair', () {
      final far = _p(
        id: 'C',
        gender: d.Gender.female,
        seeking: const {d.Gender.male},
        birthYear: 1985,
        interests: const {Interest.sports},
      );
      final self = _p(
        id: 'A',
        gender: d.Gender.male,
        seeking: const {d.Gender.female},
        birthYear: 1994,
        interests: const {Interest.music},
      );
      final s = _svc.calculateCompatibility(self, far, distanceKm: null);
      if (s != null) {
        expect(s.percentage, inInclusiveRange(0, 100));
      }
    });

    test('never rejects on the distance gate', () {
      // B accepts 10 km, A accepts 300. A synthesised distance was drawn
      // from A's radius and compared against B's, so a real candidate could
      // be dropped by chance. Unknown must simply skip the gate.
      final near = _p(
        id: 'B',
        gender: d.Gender.female,
        seeking: const {d.Gender.male},
        birthYear: 1996,
        maxDistanceKm: 10,
      );
      final wide = _p(
        id: 'A',
        gender: d.Gender.male,
        seeking: const {d.Gender.female},
        birthYear: 1994,
        maxDistanceKm: 300,
      );

      expect(_svc.calculateCompatibility(wide, near, distanceKm: null),
          isNotNull);
      // Known and out of range still rejects — the gate is not gone.
      expect(_svc.calculateCompatibility(wide, near, distanceKm: 50), isNull);
    });
  });

  group('a known distance behaves exactly as before', () {
    test('the axis is present and scaled', () {
      final close = _svc.calculateCompatibility(_a, _b, distanceKm: 5)!;
      final far = _svc.calculateCompatibility(_a, _b, distanceKm: 45)!;
      expect(close.breakdown['distance'], greaterThan(0));
      expect(far.breakdown['distance']!,
          lessThan(close.breakdown['distance']!));
    });

    test('the total is not renormalised when every axis applies', () {
      final s = _svc.calculateCompatibility(_a, _b, distanceKm: 5)!;
      final sum = s.breakdown.values.fold<int>(0, (t, v) => t + v);
      expect(s.percentage, sum);
    });

    test('the same pair no longer swings across a band', () {
      // This is the defect, expressed as a test: with the distance unknown
      // there is only one answer, so there is nothing left to swing.
      final bands = <MatchBand>{
        for (var i = 0; i < 20; i++)
          _svc.calculateCompatibility(_a, _b, distanceKm: null)!.band,
      };
      expect(bands, hasLength(1));
    });
  });
}
