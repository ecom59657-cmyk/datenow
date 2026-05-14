import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_spacing.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../l10n/app_localizations.dart';

/// Hero CTA inviting the user to start a live date. Tap → matching screen.
class MatchCtaCard extends StatelessWidget {
  const MatchCtaCard({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: AppRadius.brXl,
        child: Container(
          padding: const EdgeInsets.all(AppSpacing.lg),
          decoration: BoxDecoration(
            gradient: AppColors.brandGradient,
            borderRadius: AppRadius.brXl,
            boxShadow: [
              BoxShadow(
                color: AppColors.brandPink.withValues(alpha: 0.45),
                blurRadius: 32,
                offset: const Offset(0, 14),
              ),
            ],
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.findDateTitle,
                      style: AppTypography.h2.copyWith(color: Colors.white),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      l10n.findDateSubtitle,
                      style: AppTypography.body.copyWith(
                        color: Colors.white.withValues(alpha: 0.85),
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              const _PulseArrow(),
            ],
          ),
        ),
      ),
    ).animate().fadeIn(duration: 500.ms).slideY(begin: 0.1, end: 0);
  }
}

class _PulseArrow extends StatelessWidget {
  const _PulseArrow();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 56,
      height: 56,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.18),
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white.withValues(alpha: 0.4)),
      ),
      child: const Icon(Icons.arrow_forward_rounded, color: Colors.white),
    )
        .animate(onPlay: (c) => c.repeat(reverse: true))
        .scale(
          duration: 1400.ms,
          begin: const Offset(1, 1),
          end: const Offset(1.06, 1.06),
          curve: Curves.easeInOut,
        );
  }
}
