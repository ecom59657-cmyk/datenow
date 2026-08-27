// The daily allowance: 3 free, 6 paid, plus a boost that shows up out of
// the blue on some days.
//
// Three separate rules live here and each fails differently. A wrong cap is
// a product decision silently changed. A boost that is genuinely random
// re-rolls on every read, so the allowance flickers between two taps and
// anyone who pulls to refresh gets unlimited dates. And a boost that leaks
// onto unlimited users is harmless but dishonest in the analytics.

import 'dart:io';

import 'package:datenow/features/profile_setup/domain/enums.dart';
import 'package:datenow/features/profile_setup/domain/user_profile.dart';
import 'package:datenow/features/quota/data/quota_repository.dart';
import 'package:datenow/features/quota/data/quota_service.dart';
import 'package:datenow/features/quota/domain/quota_status.dart';
import 'package:flutter_test/flutter_test.dart';

const _service = QuotaService();

/// A day on which [userId] is boosted, and one on which they are not.
/// Found by scanning rather than hard-coded, so the tests keep working if
/// the hash is ever retuned.
({DateTime boosted, DateTime plain}) _findDays(String userId) {
  DateTime? boosted;
  DateTime? plain;
  for (var i = 0; i < 400 && (boosted == null || plain == null); i++) {
    final day = DateTime(2026, 1, 1).add(Duration(days: i));
    final hit = _service.boostFor(userId, now: day, hasCap: true) > 0;
    if (hit) {
      boosted ??= day;
    } else {
      plain ??= day;
    }
  }
  expect(boosted, isNotNull, reason: 'no boosted day found in 400');
  expect(plain, isNotNull, reason: 'no plain day found in 400');
  return (boosted: boosted!, plain: plain!);
}

void main() {
  // -------------------------------------------------------------------
  group('the daily cap', () {
    test('a free man gets three dates', () {
      expect(_service.capFor(Gender.male, isPremium: false), 3);
      expect(QuotaService.freeDailyCap, 3);
    });

    test('a paying man gets six', () {
      expect(_service.capFor(Gender.male, isPremium: true), 6);
      expect(QuotaService.premiumDailyCap, 6);
    });

    test('paying is worth exactly double', () {
      expect(QuotaService.premiumDailyCap, QuotaService.freeDailyCap * 2);
    });

    test('women stay unlimited, paid or not', () {
      for (final premium in [true, false]) {
        expect(_service.capFor(Gender.female, isPremium: premium), isNull);
      }
    });

    test('non-binary and undeclared are unlimited too', () {
      expect(_service.capFor(Gender.nonBinary, isPremium: false), isNull);
      expect(_service.capFor(null, isPremium: false), isNull);
    });
  });

  // -------------------------------------------------------------------
  group('the surprise boost', () {
    test('the same user on the same day always gets the same answer', () {
      // The rule that keeps the allowance from flickering. A real die roll
      // here would hand out a date per read.
      final day = DateTime(2026, 8, 27);
      final first = _service.boostFor('u-1', now: day, hasCap: true);
      for (var i = 0; i < 50; i++) {
        expect(_service.boostFor('u-1', now: day, hasCap: true), first);
      }
    });

    test('the time of day does not matter, only the date', () {
      final morning = DateTime(2026, 8, 27, 7, 30);
      final night = DateTime(2026, 8, 27, 23, 59);
      expect(
        _service.boostFor('u-1', now: morning, hasCap: true),
        _service.boostFor('u-1', now: night, hasCap: true),
      );
    });

    test('it is not the same answer every day', () {
      final days = _findDays('u-1');
      expect(_service.boostFor('u-1', now: days.boosted, hasCap: true), 1);
      expect(_service.boostFor('u-1', now: days.plain, hasCap: true), 0);
    });

    test('two users do not share a fate', () {
      final day = DateTime(2026, 8, 27);
      final answers = {
        for (var i = 0; i < 40; i++)
          _service.boostFor('u-$i', now: day, hasCap: true),
      };
      expect(answers.length, 2,
          reason: 'on any given day some users are boosted and some are not');
    });

    test('it lands on roughly one day in four', () {
      var hits = 0;
      var total = 0;
      for (var u = 0; u < 60; u++) {
        for (var d = 0; d < 60; d++) {
          final day = DateTime(2026, 1, 1).add(Duration(days: d));
          if (_service.boostFor('user-$u', now: day, hasCap: true) > 0) hits++;
          total++;
        }
      }
      final rate = hits / total;
      expect(rate, greaterThan(0.18), reason: 'rate was $rate');
      expect(rate, lessThan(0.32), reason: 'rate was $rate');
    });

    test('unlimited users get nothing — infinity plus one is infinity', () {
      final days = _findDays('u-1');
      expect(_service.boostFor('u-1', now: days.boosted, hasCap: false), 0);
    });

    test('it grants exactly one date', () {
      expect(QuotaService.boostDates, 1);
      final days = _findDays('u-7');
      expect(_service.boostFor('u-7', now: days.boosted, hasCap: true), 1);
    });
  });

  // -------------------------------------------------------------------
  group('boost and ad bonus are counted separately', () {
    QuotaStatus status({int used = 0, int? cap = 3, int bonus = 0, int boost = 0}) =>
        QuotaStatus(
          usedToday: used,
          cap: cap,
          checkedAt: DateTime(2026, 1, 1),
          bonusToday: bonus,
          boostToday: boost,
        );

    test('a boosted free day is four dates, not three', () {
      expect(status(boost: 1).effectiveCap, 4);
    });

    test('a boosted paid day is seven', () {
      expect(status(cap: 6, boost: 1).effectiveCap, 7);
    });

    test('a video on top of a boost stacks', () {
      final s = status(used: 4, boost: 1, bonus: 1);
      expect(s.extraToday, 2);
      expect(s.effectiveCap, 5);
      expect(s.remaining, 1);
    });

    test('the two stay distinguishable — one is paid for, one is a gift', () {
      final s = status(bonus: 2, boost: 1);
      expect(s.bonusToday, 2);
      expect(s.boostToday, 1);
    });

    test('a boost never touches an unlimited user', () {
      final s = status(cap: null, boost: 1);
      expect(s.effectiveCap, isNull);
      expect(s.isExhausted, isFalse);
    });
  });

  // -------------------------------------------------------------------
  group('the hash agrees with Postgres', () {
    // The boost is computed twice — once in Dart for the mock, once in SQL
    // for the real thing. If the two implementations drift, the app and the
    // server disagree about which days are boosted and the user watches the
    // cap change when the screen reloads.
    //
    // These three literals are the contract. They also appear verbatim in
    // supabase/tests/quota_checks.sql, which asserts them against
    // public.quota_fnv1a. Change one side and one of the two suites fails.
    const pinned = {
      'a': 3826002220,
      'datenow': 587590907,
      '0000000a-0000-4000-8000-000000000003:2026-08-27': 801266412,
    };

    test('the pinned values still hash the same', () {
      pinned.forEach((key, expected) {
        expect(QuotaService.fnv1a(key), expected, reason: 'drifted on "$key"');
      });
    });

    test('the SQL side pins the exact same numbers', () {
      final sql = File('supabase/tests/quota_checks.sql').readAsStringSync();
      for (final value in pinned.values) {
        expect(sql, contains('$value'),
            reason: 'quota_checks.sql no longer pins $value');
      }
    });

    test('the hash stays inside 32 bits', () {
      for (final key in ['', 'x', 'x' * 500, '💥']) {
        final h = QuotaService.fnv1a(key);
        expect(h, inInclusiveRange(0, 0xFFFFFFFF), reason: 'on "$key"');
      }
    });

    test('the pinned day key really is a boosted day', () {
      // Ties the raw hash back to the decision the product makes with it.
      expect(
        _service.boostFor(
          '0000000a-0000-4000-8000-000000000003',
          now: DateTime(2026, 8, 27),
          hasCap: true,
        ),
        1,
      );
    });
  });

  // -------------------------------------------------------------------
  group('end to end through the repository', () {
    late MockQuotaRepository repo;
    setUp(() => repo = MockQuotaRepository(const QuotaService()));

    const man = UserProfile(userId: 'u-male', gender: Gender.male);
    const woman = UserProfile(userId: 'u-woman', gender: Gender.female);

    test('a free man is capped at three, or four on a boosted day', () async {
      final s = await repo.currentStatus(man, isPremium: false);
      expect(s.cap, 3);
      expect(s.effectiveCap, anyOf(3, 4));
      expect(s.effectiveCap, 3 + s.boostToday);
    });

    test('the same man paying is capped at six, or seven', () async {
      final s = await repo.currentStatus(man, isPremium: true);
      expect(s.cap, 6);
      expect(s.effectiveCap, 6 + s.boostToday);
    });

    test('the boost is identical across reads within the day', () async {
      final a = await repo.currentStatus(man, isPremium: false);
      final b = await repo.currentStatus(man, isPremium: false);
      expect(a.boostToday, b.boostToday);
    });

    test('a woman is unlimited and unboosted', () async {
      final s = await repo.currentStatus(woman, isPremium: false);
      expect(s.isUnlimited, isTrue);
      expect(s.boostToday, 0);
      expect(s.isExhausted, isFalse);
    });

    test('spending the whole allowance exhausts the day, boost included',
        () async {
      var s = await repo.currentStatus(man, isPremium: false);
      final allowance = s.effectiveCap!;
      for (var i = 0; i < allowance; i++) {
        await repo.recordMatch(man);
      }
      s = await repo.currentStatus(man, isPremium: false);
      expect(s.usedToday, allowance);
      expect(s.isExhausted, isTrue);
      expect(s.remaining, 0);
    });
  });
}
