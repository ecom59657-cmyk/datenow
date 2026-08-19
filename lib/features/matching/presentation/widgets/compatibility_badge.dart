import 'package:flutter/material.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_spacing.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../l10n/app_localizations.dart';
import '../../domain/match_score.dart';

/// Pill-shaped compatibility indicator. Shown in matching + post-call.
/// Photo intentionally not displayed alongside this widget.
///
/// It shows the *band*, not the number. Twenty of the hundred points still
/// rest on a distance we cannot measure — there is no geo backend yet, so
/// the value comes from a random draw. "87 %" reads as a measurement; it
/// isn't one, and the first user who compares two cards would catch it.
/// A band is a claim the data can actually support.
/// Flip to `true` once `profiles.location` is populated and the distance
/// axis is real (UX plan, points 3b/3c). Until then the exact figure is
/// not ours to display.
const bool kShowExactCompatibility = false;

class CompatibilityBadge extends StatelessWidget {
  const CompatibilityBadge({
    super.key,
    required this.score,
    this.compact = false,
  });

  final MatchScore score;

  /// Compact variant for inline spots; full variant shows the band label.
  final bool compact;

  Color get _color => switch (score.band) {
        MatchBand.veryHigh => AppColors.bordeaux,
        MatchBand.high => AppColors.bordeauxLight,
        MatchBand.medium => AppColors.warning,
        MatchBand.low => AppColors.textTertiary,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final color = _color;
    final band = score.band.label(l10n);
    final value = kShowExactCompatibility
        ? l10n.compatibilityValue(score.percentage)
        : band;

    // FittedBox + scaleDown lets the badge keep its intrinsic shape on wide
    // layouts but shrink gracefully on narrow ones (small iPhones, dense
    // cards) instead of overflowing horizontally.
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: compact ? AppSpacing.sm : AppSpacing.md,
          vertical: compact ? 6 : 8,
        ),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: AppRadius.brPill,
          border: Border.all(color: color.withValues(alpha: 0.5)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.bolt_rounded, color: color, size: compact ? 14 : 16),
            const SizedBox(width: 6),
            Text(
              compact || !kShowExactCompatibility ? value : '$value · $band',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              softWrap: false,
              style: AppTypography.caption.copyWith(
                color: color,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.3,
                fontSize: compact ? 12 : 13,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
