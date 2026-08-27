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
        // Only offered once there is an answer to govern. A consent switch
        // above an empty question asks someone to agree to nothing.
        if (draft.origins.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.sm),
          _ConsentSwitch(
            label: l10n.backgroundUseOriginsForMatching,
            value: draft.matchOnOrigins,
            onChanged: ctrl.setMatchOnOrigins,
          ),
        ],
        const SizedBox(height: AppSpacing.xl),

        _Label(l10n.religionLabel),
        const SizedBox(height: AppSpacing.sm),
        ChoiceChipGrid<Religion>(
          options: Religion.values,
          labelOf: (r) => r.label(l10n),
          isSelected: (r) => draft.religion == r,
          onToggle: ctrl.setReligion,
        ),
        if (draft.religion != null) ...[
          const SizedBox(height: AppSpacing.sm),
          _ConsentSwitch(
            label: l10n.backgroundUseReligionForMatching,
            value: draft.matchOnReligion,
            onChanged: ctrl.setMatchOnReligion,
          ),
        ],
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

        const SizedBox(height: AppSpacing.xl),
        // Offered whether or not anything was filled in. Consent is only
        // freely given if refusing is as visible as accepting, and an "erase"
        // button that appears once you have already answered is not the same
        // affordance as being told up front that you may skip all of this.
        // A button when there is something to erase; a plain line when there
        // is not. Refusing has to be as visible as accepting, but a button
        // that does nothing observable when tapped is its own small lie.
        Align(
          alignment: Alignment.centerLeft,
          child: hasAny
              ? TextButton.icon(
                  onPressed: ctrl.clearBackground,
                  icon: const Icon(Icons.backspace_outlined, size: 18),
                  label: Text(l10n.backgroundClear),
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.textSecondary,
                  ),
                )
              // Full width with a flexible label: the sentence is long enough
              // to overflow a min-sized Row on a narrow phone.
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.block_outlined,
                        size: 18, color: AppColors.textTertiary),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(
                        l10n.backgroundPreferNotToSay,
                        style: AppTypography.caption
                            .copyWith(color: AppColors.textTertiary),
                      ),
                    ),
                  ],
                ),
        ),
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

/// One line, one switch, one article 9 purpose.
///
/// A switch rather than a pre-ticked box: explicit consent has to be an
/// affirmative act, and taking it back has to be as easy as giving it.
class _ConsentSwitch extends StatelessWidget {
  const _ConsentSwitch({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: AppRadius.brLg,
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: AppTypography.caption.copyWith(
                  color: AppColors.textSecondary,
                  height: 1.35,
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Switch.adaptive(
              value: value,
              onChanged: onChanged,
              activeThumbColor: AppColors.bordeaux,
            ),
          ],
        ),
      ),
    );
  }
}
