import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_spacing.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../../shared/widgets/app_card.dart';

/// Quiet row on Home pointing at the weekly Discover suggestions.
///
/// It used to be a mini-card wrapped in a pink→violet gradient ring with a
/// double glow and a gradient-painted CTA — a second loud surface directly
/// under the hero, competing with it. On paper the same job is done by a
/// row: a tint icon chip, two lines, a chevron. The hero stays the only
/// filled element on the screen.
class HomeDiscoverLink extends StatelessWidget {
  const HomeDiscoverLink({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AppCard(
      onTap: onPressed,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: const BoxDecoration(
              color: AppColors.tint,
              borderRadius: AppRadius.brSm,
            ),
            child: const Icon(
              Icons.auto_awesome_rounded,
              size: 18,
              color: AppColors.bordeaux,
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  l10n.homeDiscoverProfilesCta,
                  style: AppTypography.bodyStrong,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 1),
                Text(
                  l10n.homeDiscoverProfilesHint,
                  style: AppTypography.caption,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const Icon(
            Icons.chevron_right_rounded,
            color: AppColors.ink3,
            size: 22,
          ),
        ],
      ),
    ).animate().fadeIn(duration: 500.ms, delay: 380.ms);
  }
}
