import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_spacing.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../l10n/app_localizations.dart';

/// Home hero — the one filled bordeaux surface on the screen, and the only
/// place the signature gradient appears.
///
/// It used to be a 468 px wall of blurred "presence" orbs under two black
/// scrims, with the second title line painted in a hot pink→magenta
/// gradient. That composition was doing three jobs at once (atmosphere,
/// promise, CTA) and none of them clearly; it also faked a crowd, which is
/// exactly what the store listing must not do. What is left says the same
/// thing in a quarter of the height: what this is, what it costs you (five
/// minutes), and one way in.
class HomeHeroCard extends StatelessWidget {
  const HomeHeroCard({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: const BoxDecoration(
        gradient: AppColors.signatureGradient,
        borderRadius: AppRadius.brLg,
      ),
      child: Stack(
        children: [
          // Single decorative disc, barely lighter than the ground — the
          // only ornament the card gets.
          Positioned(
            top: -64,
            right: -58,
            child: IgnorePointer(
              child: Container(
                width: 160,
                height: 160,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white.withValues(alpha: 0.06),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  l10n.tonightOnDatenow.toUpperCase(),
                  style: AppTypography.overline.copyWith(
                    color: Colors.white.withValues(alpha: 0.72),
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  '${l10n.homeHeroTitleLead}\n${l10n.homeHeroTitleAccent}',
                  style: AppTypography.h2.copyWith(color: Colors.white),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  '${l10n.homeHeroSubtitleStrong} '
                  '${l10n.homeHeroSubtitleSoft}',
                  style: AppTypography.body.copyWith(
                    color: Colors.white.withValues(alpha: 0.78),
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                _HeroCta(label: l10n.homeHeroCta, onPressed: onPressed),
              ],
            ),
          ),
        ],
      ),
    ).animate().fadeIn(duration: 450.ms);
  }
}

/// Ivory pill on the bordeaux ground — the inverse of every other primary
/// button in the app, which is what marks it as *the* action.
class _HeroCta extends StatelessWidget {
  const _HeroCta({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: ExcludeSemantics(
        child: Material(
          color: AppColors.ivory,
          borderRadius: AppRadius.brPill,
          child: InkWell(
            onTap: onPressed,
            borderRadius: AppRadius.brPill,
            child: Container(
              height: 52,
              width: double.infinity,
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              child: Text(
                label,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTypography.button.copyWith(
                  color: AppColors.bordeaux,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
