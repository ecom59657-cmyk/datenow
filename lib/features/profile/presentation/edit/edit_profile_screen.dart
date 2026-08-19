// `Orientation` collides with Flutter's screen-orientation enum from
// MediaQuery — we hide it so our profile-setup enum wins in this file.
import 'package:flutter/material.dart' hide Orientation;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_spacing.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../core/utils/extensions.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../../shared/widgets/app_button.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../../../shared/widgets/app_text_field.dart';
import '../../../../shared/widgets/glass_card.dart';
import '../../../profile_setup/data/profile_repository.dart';
import '../../../profile_setup/domain/enums.dart';
import '../../../profile_setup/domain/user_profile.dart';
import '../../../profile_setup/presentation/providers/profile_provider.dart';
import '../../../profile_setup/presentation/widgets/choice_chip_grid.dart';

/// Edits the user's "identity" half of the profile: first name, gender,
/// orientation. The date of birth is captured at sign up and shown read-only
/// — changing it should require identity verification, which is out of
/// scope for the MVP.
class EditProfileScreen extends ConsumerStatefulWidget {
  const EditProfileScreen({super.key});

  @override
  ConsumerState<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends ConsumerState<EditProfileScreen> {
  // Baseline — refreshed every time the saved profile changes (initial load
  // and after a successful save). The save button is enabled iff at least
  // one field diverges from this snapshot.
  String _initialName = '';
  Gender? _initialGender;
  Orientation? _initialOrientation;

  late final TextEditingController _nameCtrl;
  Gender? _gender;
  Orientation? _orientation;
  bool _saving = false;
  bool _loaded = false;

  void _populateFrom(UserProfile profile) {
    if (_loaded) return;
    _loaded = true;
    _initialName = profile.firstName ?? '';
    _initialGender = profile.gender;
    _initialOrientation = profile.orientation;
    _nameCtrl = TextEditingController(text: _initialName);
    _gender = _initialGender;
    _orientation = _initialOrientation;
  }

  @override
  void dispose() {
    if (_loaded) {
      _nameCtrl.dispose();
    }
    super.dispose();
  }

  bool get _isValid =>
      _nameCtrl.text.trim().isNotEmpty &&
      _gender != null &&
      _orientation != null;

  bool get _isDirty =>
      _nameCtrl.text.trim() != _initialName.trim() ||
      _gender != _initialGender ||
      _orientation != _initialOrientation;

  Future<void> _save(UserProfile current) async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty || _gender == null || _orientation == null) {
      return;
    }

    setState(() => _saving = true);
    final updated = current.copyWith(
      firstName: name,
      gender: _gender,
      orientation: _orientation,
    );
    await ref.read(profileRepositoryProvider).saveProfile(updated);
    if (!mounted) return;

    // Re-baseline so the form is clean again and the button goes back to its
    // disabled state until the next edit.
    setState(() {
      _initialName = updated.firstName ?? '';
      _initialGender = updated.gender;
      _initialOrientation = updated.orientation;
      _saving = false;
    });
    final l10n = AppLocalizations.of(context);
    context.showSnack(l10n.savedSnack);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final profileAsync = ref.watch(currentProfileProvider);

    return profileAsync.when(
      loading: () => const AppScaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => AppScaffold(
          body: Center(child: Text(AppLocalizations.of(context).errorLoadProfile))),
      data: (profile) {
        if (profile == null) {
          return const AppScaffold(body: SizedBox.shrink());
        }
        _populateFrom(profile);

        final canSave = _isValid && _isDirty && !_saving;

        return AppScaffold(
          appBar: AppBar(
            title: Text(l10n.editProfileTitle),
            leading: const BackButton(),
          ),
          body: Column(
            children: [
              Expanded(
                child: ListView(
                  padding: EdgeInsets.zero,
                  children: [
                    const SizedBox(height: AppSpacing.md),
                    AppTextField(
                      controller: _nameCtrl,
                      label: l10n.firstNameLabel,
                      hint: l10n.firstNameHint,
                      prefixIcon: Icons.person_outline_rounded,
                      textInputAction: TextInputAction.next,
                      onChanged: (_) => setState(() {}),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    if (profile.birthDate != null)
                      _BirthDateLockedCard(
                        birthDate: profile.birthDate!,
                        age: profile.age!,
                      ),
                    const SizedBox(height: AppSpacing.xl),
                    _Label(l10n.genderLabel),
                    const SizedBox(height: AppSpacing.sm),
                    ChoiceChipGrid<Gender>(
                      options: Gender.values,
                      labelOf: (g) => g.label(l10n),
                      isSelected: (g) => _gender == g,
                      onToggle: (g) => setState(() => _gender = g),
                    ),
                    const SizedBox(height: AppSpacing.xl),
                    _Label(l10n.orientationLabel),
                    const SizedBox(height: AppSpacing.sm),
                    ChoiceChipGrid<Orientation>(
                      options: Orientation.values,
                      labelOf: (o) => o.label(l10n),
                      isSelected: (o) => _orientation == o,
                      onToggle: (o) => setState(() => _orientation = o),
                    ),
                    const SizedBox(height: AppSpacing.xxl),
                  ],
                ),
              ),
              AppButton(
                label: l10n.saveAction,
                size: AppButtonSize.large,
                isLoading: _saving,
                onPressed: canSave ? () => _save(profile) : null,
              ),
              const SizedBox(height: AppSpacing.lg),
            ],
          ),
        );
      },
    );
  }
}

class _BirthDateLockedCard extends StatelessWidget {
  const _BirthDateLockedCard({required this.birthDate, required this.age});

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
