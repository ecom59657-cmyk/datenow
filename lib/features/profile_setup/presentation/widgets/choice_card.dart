import 'package:flutter/material.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_spacing.dart';
import '../../../../app/theme/app_typography.dart';

/// Larger selectable card with a title + optional body line. Used for
/// intentions and availability — choices where the user needs a sentence
/// of context, not just a label.
class ChoiceCard extends StatelessWidget {
  const ChoiceCard({
    super.key,
    required this.title,
    this.body,
    required this.selected,
    required this.onTap,
    this.icon,
  });

  final String title;
  final String? body;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: AppRadius.brLg,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.all(AppSpacing.md),
          decoration: BoxDecoration(
            color: selected ? AppColors.pinkSoft : AppColors.surface,
            borderRadius: AppRadius.brLg,
            border: Border.all(
              color: selected ? AppColors.bordeaux : AppColors.hairline,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (icon != null) ...[
                Container(
                  width: 36,
                  height: 36,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: selected
                        ? AppColors.bordeaux.withValues(alpha: 0.18)
                        : AppColors.hairlineSoft,
                    borderRadius: AppRadius.brSm,
                  ),
                  child: Icon(icon,
                      size: 18,
                      color: selected
                          ? AppColors.bordeaux
                          : AppColors.textSecondary),
                ),
                const SizedBox(width: AppSpacing.sm),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: AppTypography.bodyStrong),
                    if (body != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        body!,
                        style: AppTypography.caption.copyWith(
                          color: AppColors.textTertiary,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              AnimatedOpacity(
                duration: const Duration(milliseconds: 200),
                opacity: selected ? 1 : 0,
                child: const Icon(
                  Icons.check_circle_rounded,
                  color: AppColors.bordeaux,
                  size: 22,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
