import '../../profile_setup/domain/enums.dart';

/// Pure policy: how many dates a profile gets per day, and whether today
/// carries a surprise boost. Stateless on purpose — the same rules have to
/// hold in the in-memory mock, in a widget test, and later in Postgres.
class QuotaService {
  const QuotaService();

  /// Daily cap for a capped profile without a subscription.
  static const int freeDailyCap = 3;

  /// Daily cap for a capped profile with an active subscription. Paying
  /// doubles the allowance rather than removing it: an unlimited paid tier
  /// makes the cap meaningless for the people most likely to hit it.
  static const int premiumDailyCap = 6;

  /// One in this many days carries the surprise boost. Tuned here rather
  /// than at the call site so a product decision is a one-line change.
  static const int boostOneInN = 4;

  /// Extra dates granted on a boosted day.
  static const int boostDates = 1;

  /// Daily cap of dates.
  ///
  /// - `Gender.male` → [freeDailyCap], or [premiumDailyCap] when paying
  /// - everyone else (women, non-binary, undeclared) → `null` = unlimited
  ///
  /// The asymmetry is deliberate and matches the rest of the category: the
  /// scarce side of the marketplace is not the side worth rationing.
  int? capFor(Gender? gender, {required bool isPremium}) {
    if (gender != Gender.male) return null;
    return isPremium ? premiumDailyCap : freeDailyCap;
  }

  /// The `userId:YYYY-MM-DD` key a day's counters hang off. Local midnight,
  /// which is the boundary the user actually experiences.
  String dayKey(String userId, [DateTime? now]) {
    final d = now ?? DateTime.now();
    final yyyy = d.year.toString().padLeft(4, '0');
    final mm = d.month.toString().padLeft(2, '0');
    final dd = d.day.toString().padLeft(2, '0');
    return '$userId:$yyyy-$mm-$dd';
  }

  /// Extra dates offered today, out of the blue, to a capped user.
  ///
  /// Random-feeling but **deterministic**: derived from a hash of
  /// (user, day), never from a die roll. A fresh roll on every read would
  /// let the allowance flicker between two taps of the same button — and
  /// would hand out an unbounded number of dates to anyone who pulls to
  /// refresh. The same input always yields the same answer, on any device,
  /// which is also what lets Postgres reproduce it later.
  ///
  /// Returns 0 for unlimited users: a boost on top of infinity is nothing.
  int boostFor(String userId, {DateTime? now, required bool hasCap}) {
    if (!hasCap) return 0;
    return _isBoostedDay(dayKey(userId, now)) ? boostDates : 0;
  }

  /// FNV-1a, 32-bit. Hand-rolled rather than `String.hashCode` because that
  /// carries no cross-version stability guarantee, and a boost that moves
  /// when the SDK updates is a bug report nobody can reproduce.
  ///
  /// Public so it can be pinned against `public.quota_fnv1a` in Postgres —
  /// the two must agree or the server and the client disagree about which
  /// days are boosted. See supabase/tests/quota_checks.sql.
  ///
  /// Not a security primitive. Do not use it for anything secret.
  static int fnv1a(String key) {
    var hash = 0x811c9dc5;
    for (final unit in key.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash;
  }

  bool _isBoostedDay(String key) => fnv1a(key) % boostOneInN == 0;
}
