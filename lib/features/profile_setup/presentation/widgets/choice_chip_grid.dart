import 'package:flutter/material.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_spacing.dart';
import '../../../../app/theme/app_typography.dart';

/// Wrap-style grid of selectable chips. The full chip is tappable; a thin
/// brand-coloured border (and a soft tint) marks the selected state.
class ChoiceChipGrid<T> extends StatelessWidget {
  const ChoiceChipGrid({
    super.key,
    required this.options,
    required this.labelOf,
    required this.isSelected,
    required this.onToggle,
  });

  final List<T> options;
  final String Function(T) labelOf;
  final bool Function(T) isSelected;
  final ValueChanged<T> onToggle;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: options.map((option) {
        final selected = isSelected(option);
        return _Chip(
          label: labelOf(option),
          selected: selected,
          onTap: () => onToggle(option),
        );
      }).toList(),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: AppRadius.brPill,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: 10,
          ),
          decoration: BoxDecoration(
            color: selected ? AppColors.pinkSoft : AppColors.surface,
            borderRadius: AppRadius.brPill,
            border: Border.all(
              color: selected ? AppColors.brandPink : AppColors.hairline,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Text(
            label,
            style: AppTypography.bodyStrong.copyWith(
              color: selected ? AppColors.textPrimary : AppColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}
