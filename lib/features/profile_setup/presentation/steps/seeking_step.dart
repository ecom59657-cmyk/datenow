import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_spacing.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../l10n/app_localizations.dart';
import '../../domain/enums.dart';
import '../providers/profile_setup_controller.dart';
import '../widgets/choice_chip_grid.dart';

class SeekingStep extends ConsumerWidget {
  const SeekingStep({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final ctrl = ref.read(profileSetupControllerProvider.notifier);
    final draft = ref.watch(profileSetupControllerProvider);

    return ListView(
      padding: EdgeInsets.zero,
      children: [
        Text(l10n.step2Title, style: AppTypography.h1),
        const SizedBox(height: AppSpacing.xs),
        Text(
          l10n.step2Subtitle,
          style: AppTypography.body.copyWith(color: AppColors.textSecondary),
        ),
        const SizedBox(height: AppSpacing.xl),
        _Label(l10n.seekingGenderLabel),
        const SizedBox(height: AppSpacing.sm),
        ChoiceChipGrid<Gender>(
          options: Gender.values,
          labelOf: (g) => g.label(l10n),
          isSelected: draft.seekingGenders.contains,
          onToggle: ctrl.toggleSeekingGender,
        ),
        const SizedBox(height: AppSpacing.xl),
        _LabelWithValue(
          l10n.seekingAgeLabel,
          l10n.ageRangeValue(draft.seekingAgeMin, draft.seekingAgeMax),
        ),
        const SizedBox(height: AppSpacing.xs),
        RangeSlider(
          values: RangeValues(
            draft.seekingAgeMin.toDouble(),
            draft.seekingAgeMax.toDouble(),
          ),
          min: 18,
          max: 80,
          divisions: 62,
          activeColor: AppColors.brandPink,
          inactiveColor: AppColors.hairline,
          onChanged: (v) => ctrl.setAgeRange(v.start.round(), v.end.round()),
        ),
        const SizedBox(height: AppSpacing.lg),
        _LabelWithValue(
          l10n.distanceLabel,
          l10n.distanceValue(draft.maxDistanceKm),
        ),
        const SizedBox(height: AppSpacing.xs),
        Slider(
          value: draft.maxDistanceKm.toDouble(),
          min: 5,
          max: 200,
          divisions: 39,
          activeColor: AppColors.brandPink,
          inactiveColor: AppColors.hairline,
          onChanged: (v) => ctrl.setMaxDistance(v.round()),
        ),
        const SizedBox(height: AppSpacing.xxl),
      ],
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: AppTypography.caption.copyWith(
        color: AppColors.textSecondary,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.3,
      ),
    );
  }
}

class _LabelWithValue extends StatelessWidget {
  const _LabelWithValue(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: AppTypography.caption.copyWith(
            color: AppColors.textSecondary,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.3,
          ),
        ),
        Text(value, style: AppTypography.bodyStrong),
      ],
    );
  }
}
