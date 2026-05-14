import '../../profile_setup/domain/enums.dart';

/// Pure policy: how many free matches a profile gets per day based on
/// gender. Keeping this stateless lets us unit-test the rule and reuse it
/// from any repository implementation.
class QuotaService {
  const QuotaService();

  /// Daily cap of free matches.
  ///
  /// - `Gender.male` → 5 matches per day
  /// - everyone else (women, non-binary, undeclared) → `null` = unlimited
  ///
  /// When the product expands (paid tiers, regional caps, premium unlocks),
  /// this is the single place to update.
  static const int maleDailyCap = 5;

  int? capFor(Gender? gender) {
    if (gender == Gender.male) return maleDailyCap;
    return null;
  }
}
