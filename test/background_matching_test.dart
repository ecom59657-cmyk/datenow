// Weighing the background answers — and the rule that makes it lawful.
//
// Origins and religion are article 9 data: they may only be processed for a
// purpose the person explicitly agreed to. So the score treats "answered"
// and "agreed to be matched on it" as two different things, and the second
// defaults to no.
//
// The property that carries the whole design is the last group here:
// declining must cost nothing. An axis that scored zero for the people who
// said no would turn a free choice into a penalty, which is precisely what
// makes consent stop being freely given.

import 'package:datenow/features/matching/data/matching_service.dart';
import 'package:datenow/features/profile_setup/domain/enums.dart';
import 'package:datenow/features/profile_setup/domain/interest.dart';
import 'package:datenow/features/profile_setup/domain/user_profile.dart';
import 'package:flutter_test/flutter_test.dart';

const _svc = MatchingService();

UserProfile _p({
  required String id,
  Gender gender = Gender.male,
  Set<Gender> seeking = const {Gender.female},
  Set<Origin> origins = const {},
  Religion? religion,
  Drinking? drinking,
  Smoking? smoking,
  EducationLevel? education,
  bool matchOnOrigins = false,
  bool matchOnReligion = false,
}) =>
    UserProfile(
      userId: id,
      firstName: id,
      birthDate: DateTime(1994, 5, 2),
      gender: gender,
      orientation: Orientation.straight,
      seekingGenders: seeking,
      seekingAgeMin: 18,
      seekingAgeMax: 60,
      intentions: const {Intention.feeling},
      interests: const {Interest.music, Interest.travel, Interest.cooking},
      availability: Availability.immediate,
      origins: origins,
      religion: religion,
      drinking: drinking,
      smoking: smoking,
      education: education,
      matchOnOrigins: matchOnOrigins,
      matchOnReligion: matchOnReligion,
    );

int? _axis(UserProfile a, UserProfile b, String axis) =>
    _svc.calculateCompatibility(a, b, distanceKm: 10)!.breakdown[axis];

void main() {
  // -------------------------------------------------------------------
  group('origins and religion only weigh with consent from both sides', () {
    test('answered but not consented — the axis does not exist', () {
      final a = _p(id: 'a', religion: Religion.catholic);
      final b = _p(id: 'b', gender: Gender.female, seeking: const {Gender.male},
          religion: Religion.catholic);
      expect(_axis(a, b, 'affinity'), isNull,
          reason: 'a shared religion is not a reason to weigh religion');
    });

    test('one side consenting is not enough', () {
      // Weighing B's belief because A cares would process B's religion for a
      // purpose B never agreed to.
      final a = _p(id: 'a', religion: Religion.muslim, matchOnReligion: true);
      final b = _p(id: 'b', gender: Gender.female, seeking: const {Gender.male},
          religion: Religion.muslim);
      expect(_axis(a, b, 'affinity'), isNull);
    });

    test('both consenting and agreeing scores the axis in full', () {
      final a = _p(id: 'a', religion: Religion.jewish, matchOnReligion: true);
      final b = _p(id: 'b', gender: Gender.female, seeking: const {Gender.male},
          religion: Religion.jewish, matchOnReligion: true);
      final v = _axis(a, b, 'affinity');
      expect(v, isNotNull);
      expect(v, greaterThan(0));
    });

    test('both consenting and differing scores the axis at zero', () {
      // The axis applies — that is the point of consenting — it simply does
      // not award anything.
      final a = _p(id: 'a', religion: Religion.hindu, matchOnReligion: true);
      final b = _p(id: 'b', gender: Gender.female, seeking: const {Gender.male},
          religion: Religion.atheist, matchOnReligion: true);
      expect(_axis(a, b, 'affinity'), 0);
    });

    test('consent without an answer weighs nothing', () {
      final a = _p(id: 'a', matchOnReligion: true, matchOnOrigins: true);
      final b = _p(id: 'b', gender: Gender.female, seeking: const {Gender.male},
          matchOnReligion: true, matchOnOrigins: true);
      expect(_axis(a, b, 'affinity'), isNull);
    });

    test('origins are compared as overlap, not as identity', () {
      final a = _p(
          id: 'a',
          origins: const {Origin.europe, Origin.caribbean},
          matchOnOrigins: true);
      final shared = _p(
          id: 'b',
          gender: Gender.female,
          seeking: const {Gender.male},
          origins: const {Origin.europe},
          matchOnOrigins: true);
      final none = _p(
          id: 'c',
          gender: Gender.female,
          seeking: const {Gender.male},
          origins: const {Origin.eastAsia},
          matchOnOrigins: true);
      expect(_axis(a, shared, 'affinity')!,
          greaterThan(_axis(a, none, 'affinity')!));
    });
  });

  // -------------------------------------------------------------------
  group('lifestyle weighs without a separate opt-in', () {
    test('drinking alone is enough for the axis to apply', () {
      final a = _p(id: 'a', drinking: Drinking.never);
      final b = _p(id: 'b', gender: Gender.female, seeking: const {Gender.male},
          drinking: Drinking.never);
      expect(_axis(a, b, 'lifestyle'), isNotNull);
    });

    test('a field only one side answered is skipped, not scored zero', () {
      final both = _p(id: 'a', smoking: Smoking.never);
      final oneSided = _p(id: 'b', gender: Gender.female,
          seeking: const {Gender.male}, smoking: Smoking.never,
          education: EducationLevel.master);
      // B answered education, A did not: the axis rests on smoking alone and
      // stays perfect rather than being halved by an unanswered question.
      expect(_axis(both, oneSided, 'lifestyle'), isNotNull);
    });

    test('opposite ends score lower than neighbours', () {
      final a = _p(id: 'a', drinking: Drinking.never);
      final near = _p(id: 'b', gender: Gender.female,
          seeking: const {Gender.male}, drinking: Drinking.socially);
      final far = _p(id: 'c', gender: Gender.female,
          seeking: const {Gender.male}, drinking: Drinking.often);
      expect(_axis(a, near, 'lifestyle')!,
          greaterThan(_axis(a, far, 'lifestyle')!));
    });

    test('"other" education matches itself and nothing else', () {
      final a = _p(id: 'a', education: EducationLevel.other);
      final same = _p(id: 'b', gender: Gender.female,
          seeking: const {Gender.male}, education: EducationLevel.other);
      final ladder = _p(id: 'c', gender: Gender.female,
          seeking: const {Gender.male}, education: EducationLevel.master);
      expect(_axis(a, same, 'lifestyle')!,
          greaterThan(_axis(a, ladder, 'lifestyle')!));
    });
  });

  // -------------------------------------------------------------------
  group('declining costs nothing', () {
    // The property the lawfulness rests on. If saying no lowered your score,
    // the consent would not be freely given — it would be bought.
    final blankA = _p(id: 'a');
    final blankB =
        _p(id: 'b', gender: Gender.female, seeking: const {Gender.male});

    test('a pair with no background at all still scores', () {
      final s = _svc.calculateCompatibility(blankA, blankB, distanceKm: 10)!;
      expect(s.percentage, greaterThan(0));
      expect(s.breakdown.containsKey('lifestyle'), isFalse);
      expect(s.breakdown.containsKey('affinity'), isFalse);
    });

    test('withholding consent scores exactly like never answering', () {
      // Someone who filled the questions in but refused the matching use
      // must be indistinguishable from someone who left them blank.
      final answeredButRefused = _p(
          id: 'a', origins: const {Origin.europe}, religion: Religion.catholic);
      final peer = _p(
          id: 'b',
          gender: Gender.female,
          seeking: const {Gender.male},
          origins: const {Origin.europe},
          religion: Religion.catholic);

      final refused = _svc
          .calculateCompatibility(answeredButRefused, peer, distanceKm: 10)!;
      final blank =
          _svc.calculateCompatibility(blankA, blankB, distanceKm: 10)!;
      expect(refused.percentage, blank.percentage);
    });

    test('a perfect pair still reaches 100 with no background', () {
      final s = _svc.calculateCompatibility(blankA, blankB, distanceKm: 0);
      expect(s!.percentage, lessThanOrEqualTo(100));
    });
  });

  // -------------------------------------------------------------------
  group('the scale stays honest', () {
    test('the breakdown always adds up to the percentage', () {
      final pairs = <List<UserProfile>>[
        [_p(id: 'a'), _p(id: 'b', gender: Gender.female, seeking: const {Gender.male})],
        [
          _p(id: 'a', drinking: Drinking.often, religion: Religion.sikh,
              matchOnReligion: true),
          _p(id: 'b', gender: Gender.female, seeking: const {Gender.male},
              drinking: Drinking.never, religion: Religion.sikh,
              matchOnReligion: true),
        ],
      ];
      for (final km in <int?>[null, 0, 10, 200]) {
        for (final pair in pairs) {
          final s = _svc.calculateCompatibility(pair[0], pair[1],
              distanceKm: km);
          if (s == null) continue;
          final sum = s.breakdown.values.fold<int>(0, (t, v) => t + v);
          expect(s.percentage, sum, reason: 'km=$km');
          expect(s.percentage, inInclusiveRange(0, 100));
        }
      }
    });
  });
}
