import 'package:flutter/material.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_spacing.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../l10n/app_localizations.dart';
import '../../domain/match_score.dart';

/// Pill-shaped compatibility indicator. Shown in matching + post-call.
/// Photo intentionally not displayed alongside this widget.
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
        MatchBand.veryHigh => AppColors.brandPink,
        MatchBand.high => AppColors.brandViolet,
        MatchBand.medium => AppColors.warning,
        MatchBand.low => AppColors.textTertiary,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final color = _color;
    final value = l10n.compatibilityValue(score.percentage);

    return Container(
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
            compact ? value : '$value · ${score.band.label(l10n)}',
            style: AppTypography.caption.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.3,
              fontSize: compact ? 12 : 13,
            ),
          ),
        ],
      ),
    );
  }
}
