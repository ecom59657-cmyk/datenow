import 'package:flutter/material.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_spacing.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../core/utils/profile_format.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../../shared/widgets/glass_card.dart';
import '../../../matching/domain/match_score.dart';
import '../../../matching/presentation/widgets/compatibility_badge.dart';
import '../../domain/match_status.dart';
import '../../domain/mutual_match.dart';

/// Card for a confirmed mutual match. The candidate's photo is allowed here
/// — it was already revealed during the post-call screen, which is the
/// privacy boundary for the product.
///
/// We don't ship real candidate photos in mock mode, so this widget uses a
/// brand-gradient avatar with the candidate's first initial. Once a real
/// backend serves a `photoUrl`, swap [ _Avatar ] for a network image.
class MatchCard extends StatelessWidget {
  const MatchCard({super.key, required this.match, this.onTap});

  final MutualMatch match;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final candidate = match.candidate;
    final score = MatchScore(
      percentage: match.compatibilityScore,
      breakdown: const {},
    );

    return GlassCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      onTap: onTap,
      child: Row(
        children: [
          _Avatar(initial: candidate.firstName?.characters.first ?? '?'),
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
                  style: AppTypography.bodyStrong,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                _StatusPill(label: match.status.label(l10n)),
              ],
            ),
          ),
          CompatibilityBadge(score: score, compact: true),
          if (onTap != null) ...[
            const SizedBox(width: AppSpacing.xs),
            const Icon(
              Icons.chat_bubble_outline_rounded,
              color: AppColors.textTertiary,
              size: 18,
            ),
          ],
        ],
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.initial});

  final String initial;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 52,
      height: 52,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        gradient: AppColors.brandGradient,
      ),
      alignment: Alignment.center,
      child: Text(
        initial.toUpperCase(),
        style: AppTypography.bodyStrong.copyWith(
          color: Colors.white,
          fontSize: 20,
        ),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.brandPink.withValues(alpha: 0.14),
        borderRadius: AppRadius.brPill,
        border: Border.all(color: AppColors.brandPink.withValues(alpha: 0.4)),
      ),
      child: Text(
        label,
        style: AppTypography.caption.copyWith(
          color: AppColors.brandPink,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}
