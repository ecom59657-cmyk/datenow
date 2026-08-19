import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_spacing.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../l10n/app_localizations.dart';
import '../../domain/enums.dart';
import '../providers/profile_setup_controller.dart';
import '../widgets/choice_chip_grid.dart';

/// Signup step 2 — the five optional attributes.
///
/// Nothing here gates the wizard. `_validForStep` returns true for this
/// index unconditionally, so the primary button reads "Continuer" from the
/// moment the step opens and someone who wants to answer none of it loses
/// one tap, not a signup.
///
/// Origins and religion are special-category data under article 9 of the
/// GDPR and "Sensitive Info" in Apple's privacy labels. Three consequences
/// are visible in this file:
///
///   * the subtitle says the step is skippable before the first question,
///     not after the last one;
///   * a sentence names the two sensitive fields and says they are only
///     stored if filled — consent has to be informed to be consent;
///   * "Tout effacer" is one tap and always available, because the right to
///     withdraw is worth nothing if it is buried in a settings screen.
///
/// Not answering stores nothing: there is no "prefers not to say" value,
/// which would itself be an answer on a subject the person declined.
class BackgroundStep extends ConsumerWidget {
  const BackgroundStep({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final draft = ref.watch(profileSetupControllerProvider);
    final ctrl = ref.read(profileSetupControllerProvider.notifier);

    final hasAny = draft.origins.isNotEmpty ||
        draft.religion != null ||
        draft.drinking != null ||
        draft.smoking != null ||
        draft.education != null;

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      children: [
        const SizedBox(height: AppSpacing.sm),
        Text(l10n.backgroundStepTitle, style: AppTypography.h1),
        const SizedBox(height: AppSpacing.sm),
        Text(
          l10n.backgroundStepSubtitle,
          style: AppTypography.body.copyWith(color: AppColors.textSecondary),
        ),
        const SizedBox(height: AppSpacing.lg),
        const _SensitiveNote(),
        const SizedBox(height: AppSpacing.xl),

        _Label(l10n.originsLabel),
        const SizedBox(height: AppSpacing.sm),
        // Multi-select: a single slot forces mixed heritage to pick a side.
        ChoiceChipGrid<Origin>(
          options: Origin.values,
          labelOf: (o) => o.label(l10n),
          isSelected: draft.origins.contains,
          onToggle: ctrl.toggleOrigin,
        ),
        const SizedBox(height: AppSpacing.xl),

        _Label(l10n.religionLabel),
        const SizedBox(height: AppSpacing.sm),
        ChoiceChipGrid<Religion>(
          options: Religion.values,
          labelOf: (r) => r.label(l10n),
          isSelected: (r) => draft.religion == r,
          onToggle: ctrl.setReligion,
        ),
        const SizedBox(height: AppSpacing.xl),

        _Label(l10n.drinkingLabel),
        const SizedBox(height: AppSpacing.sm),
        ChoiceChipGrid<Drinking>(
          options: Drinking.values,
          labelOf: (d) => d.label(l10n),
          isSelected: (d) => draft.drinking == d,
          onToggle: ctrl.setDrinking,
        ),
        const SizedBox(height: AppSpacing.xl),

        _Label(l10n.smokingLabel),
        const SizedBox(height: AppSpacing.sm),
        ChoiceChipGrid<Smoking>(
          options: Smoking.values,
          labelOf: (s) => s.label(l10n),
          isSelected: (s) => draft.smoking == s,
          onToggle: ctrl.setSmoking,
        ),
        const SizedBox(height: AppSpacing.xl),

        _Label(l10n.educationLabel),
        const SizedBox(height: AppSpacing.sm),
        ChoiceChipGrid<EducationLevel>(
          options: EducationLevel.values,
          labelOf: (e) => e.label(l10n),
          isSelected: (e) => draft.education == e,
          onToggle: ctrl.setEducation,
        ),

        if (hasAny) ...[
          const SizedBox(height: AppSpacing.xl),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: ctrl.clearBackground,
              icon: const Icon(Icons.backspace_outlined, size: 18),
              label: Text(l10n.backgroundClear),
              style: TextButton.styleFrom(
                foregroundColor: AppColors.textSecondary,
              ),
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.xxl),
      ],
    );
  }
}

/// Says plainly which two answers are sensitive and what happens to them.
class _SensitiveNote extends StatelessWidget {
  const _SensitiveNote();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: const BoxDecoration(
        color: AppColors.sand,
        borderRadius: AppRadius.brLg,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.lock_outline_rounded,
            size: 18,
            color: AppColors.clay,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              l10n.backgroundSensitiveNote,
              style: AppTypography.caption.copyWith(
                color: AppColors.textSecondary,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
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
