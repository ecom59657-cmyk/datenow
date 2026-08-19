import 'package:flutter/material.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_spacing.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../shared/widgets/app_card.dart';

class StatTile extends StatelessWidget {
  const StatTile({
    super.key,
    required this.icon,
    required this.value,
    required this.label,
    this.accent,
    this.onTap,
  });

  final IconData icon;
  final String value;
  final String label;
  final Color? accent;

  /// When provided, the whole tile becomes tappable (ink ripple + haptic)
  /// and shows a chevron so it reads as a navigation shortcut.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final color = accent ?? AppColors.bordeaux;
    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  // Fixed tint ground rather than an alpha wash of the
                  // accent, which turned muddy on paper.
                  color: color == AppColors.bordeaux
                      ? AppColors.tint
                      : AppColors.clayTint,
                  borderRadius: AppRadius.brSm,
                ),
                child: Icon(icon, color: color, size: 18),
              ),
              if (onTap != null) ...[
                const Spacer(),
                const Icon(
                  Icons.chevron_right_rounded,
                  color: AppColors.ink3,
                  size: 22,
                ),
              ],
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(value, style: AppTypography.h2),
          const SizedBox(height: 2),
          Text(
            label,
            style: AppTypography.caption,
          ),
        ],
      ),
    );
  }
}
