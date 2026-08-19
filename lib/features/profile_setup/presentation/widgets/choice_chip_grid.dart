import 'package:flutter/material.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_spacing.dart';
import '../../../../app/theme/app_typography.dart';

/// Wrap-style grid of selectable chips. The full chip is tappable and a
/// selected chip fills with bordeaux.
///
/// Chips used to be 41 px tall — under the 48 px minimum tap target, on a
/// screen where users pick a dozen of them in a row.
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
          constraints: const BoxConstraints(minHeight: 48),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: 12,
          ),
          decoration: BoxDecoration(
            color: selected ? AppColors.bordeaux : AppColors.paper,
            borderRadius: AppRadius.brPill,
            border: Border.all(
              color: selected ? AppColors.bordeaux : AppColors.line,
            ),
          ),
          child: Text(
            label,
            style: AppTypography.bodyStrong.copyWith(
              color: selected ? Colors.white : AppColors.ink2,
            ),
          ),
        ),
      ),
    );
  }
}
