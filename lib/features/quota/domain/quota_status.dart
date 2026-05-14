/// Snapshot of how many matches the current user has consumed today.
///
/// Read-only — fresh instances are produced by the repository on demand.
/// `cap == null` means unlimited (women + non-binary users in this MVP).
class QuotaStatus {
  const QuotaStatus({
    required this.usedToday,
    required this.cap,
    required this.checkedAt,
  });

  final int usedToday;
  final int? cap;
  final DateTime checkedAt;

  bool get isUnlimited => cap == null;
  bool get isExhausted => cap != null && usedToday >= cap!;

  /// `null` when unlimited; otherwise a non-negative count of dates left.
  int? get remaining {
    if (cap == null) return null;
    final left = cap! - usedToday;
    return left < 0 ? 0 : left;
  }
}
