/// Snapshot of how many matches the current user has consumed today.
///
/// Read-only — fresh instances are produced by the repository on demand.
/// `cap == null` means unlimited (women + non-binary users in this MVP).
class QuotaStatus {
  const QuotaStatus({
    required this.usedToday,
    required this.cap,
    required this.checkedAt,
    this.bonusToday = 0,
    this.boostToday = 0,
  });

  final int usedToday;
  final int? cap;
  final DateTime checkedAt;

  /// Extra dates earned today by watching rewarded ads. Added on top of
  /// [cap] rather than deducted from [usedToday] so the raw consumption
  /// count stays truthful for analytics.
  final int bonusToday;

  /// Extra dates offered today by the surprise daily boost. Kept apart
  /// from [bonusToday] because the two are different products: one is
  /// paid for with attention, the other is a gift. Analytics that merged
  /// them could not tell whether the ads or the boost brings people back.
  final int boostToday;

  bool get isUnlimited => cap == null;

  /// Everything granted on top of the base cap today.
  int get extraToday => bonusToday + boostToday;

  /// Effective allowance for today: the base cap plus anything earned or
  /// offered. `null` when unlimited.
  int? get effectiveCap => cap == null ? null : cap! + extraToday;

  bool get isExhausted {
    final limit = effectiveCap;
    return limit != null && usedToday >= limit;
  }

  /// `null` when unlimited; otherwise a non-negative count of dates left.
  int? get remaining {
    final limit = effectiveCap;
    if (limit == null) return null;
    final left = limit - usedToday;
    return left < 0 ? 0 : left;
  }
}
