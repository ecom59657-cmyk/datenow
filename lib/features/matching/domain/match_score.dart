import '../../../l10n/app_localizations.dart';

/// Banding used to colour-code the score in the UI.
enum MatchBand { veryHigh, high, medium, low }

extension MatchBandX on MatchBand {
  String label(AppLocalizations l) => switch (this) {
        MatchBand.veryHigh => l.compatibilityBandVeryHigh,
        MatchBand.high => l.compatibilityBandHigh,
        MatchBand.medium => l.compatibilityBandMedium,
        MatchBand.low => l.compatibilityBandLow,
      };
}

/// Result of running [MatchingService.calculateCompatibility].
///
/// `null` is returned upstream when a hard gate (reciprocal gender / age /
/// distance) fails — meaning the two profiles shouldn't even be proposed to
/// each other. A non-null score is always in `0..100`.
class MatchScore {
  const MatchScore({
    required this.percentage,
    required this.breakdown,
  });

  /// Final compatibility score, clamped to `0..100`.
  final int percentage;

  /// Per-axis breakdown — handy for debugging and for the UI to surface
  /// "what made you compatible". Keys are intentionally stable strings.
  final Map<String, int> breakdown;

  /// Thresholds were 90 / 70 / 50 when the orientation axis handed every
  /// completed profile a free 15 points. Removing it deflates every score
  /// by exactly that much, so the thresholds move with it — otherwise
  /// "Très compatible" would become practically unreachable and
  /// the bands would quietly all shift down one notch.
  MatchBand get band => bandFor(percentage);

  /// Same banding for callers that only carry the stored integer (a match
  /// row, a suggestion row) and have no breakdown to build a [MatchScore]
  /// from.
  static MatchBand bandFor(int percentage) {
    if (percentage >= 75) return MatchBand.veryHigh;
    if (percentage >= 55) return MatchBand.high;
    if (percentage >= 35) return MatchBand.medium;
    return MatchBand.low;
  }

  @override
  String toString() => 'MatchScore($percentage%, $band)';
}
