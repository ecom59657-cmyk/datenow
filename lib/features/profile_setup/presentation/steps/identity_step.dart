// `Orientation` collides with Flutter's screen-orientation enum from
// MediaQuery — we hide it so our profile-setup enum wins in this file.
import 'package:flutter/material.dart' hide Orientation;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_spacing.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../core/utils/validators.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../../shared/widgets/app_text_field.dart';
import '../../../../shared/widgets/cupertino_birth_date_picker.dart';
import '../../../../shared/widgets/glass_card.dart';
import '../../domain/enums.dart';
import '../providers/profile_setup_controller.dart';
import '../widgets/choice_chip_grid.dart';

class IdentityStep extends ConsumerStatefulWidget {
  const IdentityStep({super.key});

  @override
  ConsumerState<IdentityStep> createState() => _IdentityStepState();
}

class _IdentityStepState extends ConsumerState<IdentityStep> {
  late final TextEditingController _nameCtrl;

  @override
  void initState() {
    super.initState();
    final draft = ref.read(profileSetupControllerProvider);
    _nameCtrl = TextEditingController(text: draft.firstName ?? '');
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final ctrl = ref.read(profileSetupControllerProvider.notifier);
    final draft = ref.watch(profileSetupControllerProvider);

    return ListView(
      padding: EdgeInsets.zero,
      children: [
        Text(l10n.step1Title, style: AppTypography.h1),
        const SizedBox(height: AppSpacing.xs),
        Text(
          l10n.step1Subtitle,
          style: AppTypography.body.copyWith(color: AppColors.textSecondary),
        ),
        const SizedBox(height: AppSpacing.xl),
        AppTextField(
          controller: _nameCtrl,
          label: l10n.firstNameLabel,
          hint: l10n.firstNameHint,
          prefixIcon: Icons.person_outline_rounded,
          textInputAction: TextInputAction.next,
          onChanged: ctrl.setFirstName,
        ),
        const SizedBox(height: AppSpacing.md),
        // Two birth-date paths converge here:
        //   1. Email/OTP signup users already have DOB in auth metadata
        //      (collected on the SignUp screen) → show the read-only
        //      summary card so the 18+ rule is visible without re-asking.
        //   2. OAuth users (Apple/Google) NEVER get a DOB from the
        //      provider → show the iOS-native CupertinoBirthDatePicker
        //      so they can fill it here. Required field — isStep1Valid
        //      checks birthDate != null + age >= 18, so without this
        //      picker the "Continuer" button stays disabled forever
        //      with no on-screen path forward (the bug this fix closes).
        if (draft.birthDate != null)
          _BirthDateCard(birthDate: draft.birthDate!, age: draft.age!)
        else
          CupertinoBirthDatePicker(
            label: l10n.birthDateLabel,
            hint: l10n.birthDateHint,
            initialValue: draft.birthDate,
            validator: (v) => Validators.birthDate(v, l10n),
            onChanged: (date) {
              if (date != null) ctrl.setBirthDate(date);
            },
          ),
        const SizedBox(height: AppSpacing.xl),
        _Label(l10n.genderLabel),
        const SizedBox(height: AppSpacing.sm),
        ChoiceChipGrid<Gender>(
          options: Gender.values,
          labelOf: (g) => g.label(l10n),
          isSelected: (g) => draft.gender == g,
          onToggle: ctrl.setGender,
        ),
        const SizedBox(height: AppSpacing.xl),
        _Label(l10n.orientationLabel),
        const SizedBox(height: AppSpacing.sm),
        ChoiceChipGrid<Orientation>(
          options: Orientation.values,
          labelOf: (o) => o.label(l10n),
          isSelected: (o) => draft.orientation == o,
          onToggle: ctrl.setOrientation,
        ),
        const SizedBox(height: AppSpacing.xxl),
      ],
    );
  }
}

class _BirthDateCard extends StatelessWidget {
  const _BirthDateCard({required this.birthDate, required this.age});

  final DateTime birthDate;
  final int age;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final localeName = Localizations.localeOf(context).toString();
    final formatted = DateFormat.yMMMMd(localeName).format(birthDate);

    return GlassCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              color: AppColors.pinkSoft,
              borderRadius: AppRadius.brSm,
            ),
            child: const Icon(
              Icons.cake_outlined,
              color: AppColors.bordeaux,
              size: 18,
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.birthDateLabel, style: AppTypography.caption),
                Text(
                  '$formatted · ${l10n.birthDateAgeFormat(age)}',
                  style: AppTypography.bodyStrong,
                ),
                const SizedBox(height: 2),
                Text(
                  l10n.birthDateSetAtSignup,
                  style: AppTypography.caption.copyWith(
                    color: AppColors.textTertiary,
                  ),
                ),
              ],
            ),
          ),
          const Icon(Icons.lock_outline_rounded,
              color: AppColors.textTertiary, size: 18),
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
