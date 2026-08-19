import 'package:flutter/material.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_spacing.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../core/utils/profile_format.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../../shared/widgets/app_button.dart';
import '../../../../shared/widgets/app_card.dart';
import '../../../../shared/widgets/veil.dart';
import '../../../matching/domain/match_score.dart';
import '../../../matching/presentation/widgets/compatibility_badge.dart';
import '../../domain/weekly_suggestion.dart';

/// One weekly proposal.
///
/// The photo is hidden on purpose — it only ever surfaces after the live
/// date — and the card now says so instead of leaving a hole. It used to
/// show a 72 px circle under [VeilLevel.v4]: at that size a sigma-26 blur
/// does not hide a face, it erases it, and the result read as a rendering
/// glitch rather than as a deliberate reveal. A full-bleed veiled header
/// with a lock caption carries the same rule and makes it legible — warm
/// colour, a shape behind the veil, and a sentence explaining when it
/// opens. Same composition as the mockup, whose own caption puts it
/// plainly: "photo floutée assumée comme un parti pris, pas comme un
/// manque".
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

  /// Tall enough for the veil to read as a presence rather than a swatch.
  static const double _headerHeight = 190;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final candidate = suggestion.candidate;
    final score = MatchScore(
      percentage: suggestion.compatibilityScore,
      breakdown: const {},
    );

    return AppCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: _headerHeight,
            child: Stack(
              fit: StackFit.expand,
              children: [
                // No real photo is fetched before the call — RLS would
                // refuse it anyway. This is the warm placeholder under the
                // Veil, which is exactly what the mockup draws too.
                const Veil(
                  level: VeilLevel.v4,
                  shape: VeilShape.card,
                  child: VeilPlaceholder(icon: null),
                ),
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.lock_outline_rounded,
                        color: AppColors.paper,
                        size: 22,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        l10n.suggestionPhotoLocked,
                        textAlign: TextAlign.center,
                        style: AppTypography.caption.copyWith(
                          color: AppColors.paper,
                          fontWeight: FontWeight.w600,
                          shadows: const [
                            Shadow(
                              color: Color(0x66451523),
                              blurRadius: 6,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
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
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                // No geo backend yet: a persisted suggestion carries no
                // distance, and 0 is "unknown", not "next door". Show the
                // line only when there is a real figure to show.
                if (suggestion.distanceKm > 0) ...[
                  const SizedBox(height: 2),
                  Text('${suggestion.distanceKm} km',
                      style: AppTypography.caption),
                ],
                const SizedBox(height: AppSpacing.xs),
                CompatibilityBadge(score: score, compact: true),
                const SizedBox(height: AppSpacing.md),
                Row(
                  children: [
                    // Dismiss shrinks to an icon: it is the rare gesture,
                    // and two full-width buttons stacked made refusing look
                    // as inviting as starting.
                    SizedBox(
                      width: 52,
                      child: AppButton(
                        label: '',
                        icon: Icons.close_rounded,
                        variant: AppButtonVariant.secondary,
                        expanded: false,
                        onPressed: onDismiss,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    Expanded(
                      child: AppButton(
                        label: l10n.suggestionStartDate,
                        icon: Icons.bolt_rounded,
                        onPressed: onStartDate,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
