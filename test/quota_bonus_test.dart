// Pure-logic tests for the rewarded-ad bonus added to the daily quota.
//
// The rule this pins down is the one that costs money if it drifts: a bonus
// is granted ONLY on a confirmed reward, it raises the allowance without
// rewriting how many dates were actually consumed, and it never applies to
// unlimited users. The service that decides whether a reward happened is
// RewardedAdService — it cannot be unit-tested without the AdMob SDK, so
// what is covered here is everything downstream of "Google said yes".

import 'package:datenow/features/profile_setup/domain/enums.dart';
import 'package:datenow/features/profile_setup/domain/user_profile.dart';
import 'package:datenow/features/quota/data/quota_repository.dart';
import 'package:datenow/features/quota/data/quota_service.dart';
import 'package:datenow/features/quota/domain/quota_status.dart';
import 'package:flutter_test/flutter_test.dart';

QuotaStatus _status({required int used, int? cap, int bonus = 0}) =>
    QuotaStatus(
      usedToday: used,
      cap: cap,
      checkedAt: DateTime(2026, 1, 1),
      bonusToday: bonus,
    );

void main() {
  group('QuotaStatus with a rewarded bonus', () {
    test('a bonus lifts an exhausted user back over the line', () {
      final before = _status(used: 5, cap: 5);
      expect(before.isExhausted, isTrue);
      expect(before.remaining, 0);

      final after = _status(used: 5, cap: 5, bonus: 1);
      expect(after.isExhausted, isFalse);
      expect(after.remaining, 1);
    });

    test('the bonus raises the cap and leaves consumption untouched', () {
      final s = _status(used: 5, cap: 5, bonus: 2);
      expect(s.effectiveCap, 7);
      // usedToday must stay truthful — analytics reads it as real dates.
      expect(s.usedToday, 5);
    });

    test('bonuses accumulate across several videos', () {
      expect(_status(used: 5, cap: 5, bonus: 3).remaining, 3);
    });

    test('unlimited users are unaffected by a bonus', () {
      final s = _status(used: 12, cap: null, bonus: 4);
      expect(s.isUnlimited, isTrue);
      expect(s.effectiveCap, isNull);
      expect(s.remaining, isNull);
      expect(s.isExhausted, isFalse);
    });

    test('remaining never goes negative when usage overshoots', () {
      expect(_status(used: 9, cap: 5, bonus: 1).remaining, 0);
      expect(_status(used: 9, cap: 5, bonus: 1).isExhausted, isTrue);
    });

    test('no bonus granted leaves the original behaviour intact', () {
      final s = _status(used: 3, cap: 5);
      expect(s.effectiveCap, 5);
      expect(s.remaining, 2);
      expect(s.isExhausted, isFalse);
    });
  });

  group('MockQuotaRepository.awaitRewardedBonus', () {
    const male = UserProfile(userId: 'u-male', gender: Gender.male);
    const woman = UserProfile(userId: 'u-woman', gender: Gender.female);

    late MockQuotaRepository repo;

    setUp(() => repo = MockQuotaRepository(const QuotaService()));

    /// Spends dates until the day is done. Loops on [isExhausted] rather
    /// than on a literal count because the daily boost can quietly add one
    /// — a hard-coded loop would leave the user with a date in hand.
    Future<QuotaStatus> exhaust(UserProfile p) async {
      var status = await repo.currentStatus(p, isPremium: false);
      var guard = 0;
      while (!status.isExhausted && guard++ < 20) {
        await repo.recordMatch(p);
        status = await repo.currentStatus(p, isPremium: false);
      }
      return status;
    }

    test('a capped user who exhausted the day can date again after one ad',
        () async {
      final before = await exhaust(male);
      expect(before.isExhausted, isTrue);
      final spent = before.usedToday;

      await repo.awaitRewardedBonus(male, knownBonusToday: 0);

      final status = await repo.currentStatus(male, isPremium: false);
      expect(status.isExhausted, isFalse);
      expect(status.remaining, 1);
      expect(status.usedToday, spent,
          reason: 'the bonus lifts the cap, it does not erase consumption');
    });

    test('spending the bonus exhausts the day again', () async {
      await exhaust(male);
      await repo.awaitRewardedBonus(male, knownBonusToday: 0);
      await repo.recordMatch(male);

      expect((await repo.currentStatus(male, isPremium: false)).isExhausted,
          isTrue);
    });

    test('bonuses are scoped to one user, not shared', () async {
      await repo.awaitRewardedBonus(male, knownBonusToday: 0);
      final other = await repo.currentStatus(
        const UserProfile(userId: 'u-other', gender: Gender.male),
        isPremium: false,
      );
      expect(other.bonusToday, 0);
    });

    test('granting to an unlimited user changes nothing observable', () async {
      await repo.awaitRewardedBonus(woman, knownBonusToday: 0);
      final status = await repo.currentStatus(woman, isPremium: false);
      expect(status.isUnlimited, isTrue);
      expect(status.remaining, isNull);
    });
  });
}
