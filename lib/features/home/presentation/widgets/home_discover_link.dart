import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_spacing.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../l10n/app_localizations.dart';

/// Secondary CTA on Home — a quiet, premium ghost link that points to
/// the weekly Discover screen.
///
/// Visual contract:
///   • Sits directly under the immersive hero ("Trouver un date" white
///     pill). Its job is to make the **curated** path visible without
///     competing with the live CTA.
///   • No fill, no glow, no continuous pulse — a single elegant fade-in
///     on mount and an InkWell splash on tap.
///   • A small brand-violet sparkle (vs the pink heart of live) acts as
///     a subliminal cue: "this is the considered / hand-picked path".
///   • Two-line stack — action verb on top, soft hint underneath — so
///     the difference with the live CTA reads at a glance, with zero
///     extra prose elsewhere on the screen.
///   • Tap target ≥ 56 pt to honour iOS HIG (`pointerInteractive` row
///     + descender included).
class HomeDiscoverLink extends StatelessWidget {
  const HomeDiscoverLink({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Center(
      child: Material(
        color: Colors.transparent,
        borderRadius: AppRadius.brPill,
        child: InkWell(
          onTap: onPressed,
          borderRadius: AppRadius.brPill,
          // Splash is brand-violet (the "curated" cue) but very dilute,
          // so even the tap feedback never out-shouts the live pill above.
          splashColor: AppColors.brandViolet.withValues(alpha: 0.10),
          highlightColor: AppColors.brandViolet.withValues(alpha: 0.05),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: AppSpacing.sm,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.auto_awesome_rounded,
                        size: 16,
                        color: AppColors.brandViolet,
                      ),
                      const SizedBox(width: AppSpacing.xs),
                      Text(
                        l10n.homeDiscoverProfilesCta,
                        style: AppTypography.button.copyWith(
                          color: AppColors.textPrimary,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.2,
                        ),
                      ),
                      const SizedBox(width: 4),
                      const Icon(
                        Icons.chevron_right_rounded,
                        size: 20,
                        color: AppColors.textSecondary,
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    l10n.homeDiscoverProfilesHint,
                    style: AppTypography.caption.copyWith(
                      color: AppColors.textTertiary,
                      letterSpacing: 0.1,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    )
        // Match the hero CTA's intro choreography (fade + slide-up) but
        // arrive a beat later so the eye lands on the live pill first.
        .animate()
        .fadeIn(duration: 500.ms, delay: 380.ms)
        .slideY(begin: 0.18, end: 0, curve: Curves.easeOut);
  }
}
