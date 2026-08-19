import 'package:flutter/material.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_spacing.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../core/utils/profile_format.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../../shared/widgets/app_button.dart';
import '../../../../shared/widgets/glass_card.dart';
import '../../../matching/presentation/widgets/compatibility_badge.dart';
import '../../../matching/domain/match_score.dart';
import '../../../profile_setup/presentation/widgets/blurred_avatar.dart';
import '../../domain/weekly_suggestion.dart';

/// Premium card for one weekly proposal. Photo is intentionally **hidden**
/// — we render the brand silhouette until the live date has actually
/// happened.
class SuggestionCard extends StatelessWidget {
  const SuggestionCard({
    super.key,
    required this.suggestion,
    required this.onStartDate,
    required this.onDismiss,
  });

  final WeeklySuggestion suggestion;
  final VoidCallback onStartDate;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final candidate = suggestion.candidate;
    final score = MatchScore(
      percentage: suggestion.compatibilityScore,
      breakdown: const {},
    );

    return GlassCard(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const BlurredAvatar(size: 72),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      formatProfileNameAge(
                        l10n,
                        firstName: candidate.firstName,
                        age: candidate.age,
                      ),
                      style: AppTypography.h3,
                    ),
                    // No geo backend yet: a persisted suggestion carries no
                    // distance, and 0 is "unknown", not "next door". Show
                    // the line only when there is a real figure to show.
                    if (suggestion.distanceKm > 0) ...[
                      const SizedBox(height: 2),
                      Text(
                        '${suggestion.distanceKm} km',
                        style: AppTypography.body.copyWith(
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                    const SizedBox(height: AppSpacing.sm),
                    CompatibilityBadge(score: score, compact: true),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          AppButton(
            label: l10n.suggestionStartDate,
            icon: Icons.bolt_rounded,
            onPressed: onStartDate,
          ),
          const SizedBox(height: AppSpacing.sm),
          AppButton(
            label: l10n.suggestionDismiss,
            icon: Icons.close_rounded,
            variant: AppButtonVariant.secondary,
            onPressed: onDismiss,
          ),
        ],
      ),
    );
  }
}
