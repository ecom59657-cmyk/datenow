import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../core/utils/extensions.dart';
import '../../../core/utils/validators.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/app_button.dart';
import '../../../shared/widgets/app_scaffold.dart';
import '../../../shared/widgets/app_text_field.dart';
import '../../profile_setup/presentation/providers/profile_provider.dart';
import '../data/settings_repository.dart';
import '../domain/settings_models.dart';
import 'providers/settings_providers.dart';
import 'widgets/setting_widgets.dart';

class SecurityScreen extends ConsumerWidget {
  const SecurityScreen({super.key});

  Future<void> _toggleTwoFactor(
    WidgetRef ref,
    BuildContext context,
    bool value,
  ) async {
    final profile = ref.read(currentProfileProvider).asData?.value;
    if (profile == null) return;
    final repo = ref.read(settingsRepositoryProvider);
    final current =
        ref.read(privacyPrefsProvider).asData?.value ?? const PrivacyPrefs();
    await repo.updatePrivacyPrefs(
      profile.userId,
      current.copyWith(twoFactorEnabled: value),
    );
    if (!context.mounted) return;
    context.showSnack(AppLocalizations.of(context).savedSnack);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final prefs =
        ref.watch(privacyPrefsProvider).asData?.value ?? const PrivacyPrefs();

    final thisDeviceLabel = l10n.securitySignInEntry(
      l10n.securityThisDevice,
      _humanWhen(DateTime.now()),
    );
    final history = <String>[
      l10n.securitySignInEntry('Paris, FR', _humanWhen(DateTime.now()
          .subtract(const Duration(hours: 4)))),
      l10n.securitySignInEntry('Lyon, FR', _humanWhen(DateTime.now()
          .subtract(const Duration(days: 2)))),
      l10n.securitySignInEntry('Brussels, BE',
          _humanWhen(DateTime.now().subtract(const Duration(days: 6)))),
    ];

    return AppScaffold(
      appBar: AppBar(
        title: Text(l10n.securityTitle),
        leading: const BackButton(),
      ),
      body: ListView(
        padding: const EdgeInsets.only(top: AppSpacing.md, bottom: 64),
        children: [
          Text(
            l10n.securitySubtitle,
            style:
                AppTypography.body.copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: AppSpacing.lg),
          SettingSection(
            title: l10n.securityTitle,
            children: [
              SettingTile(
                icon: Icons.password_rounded,
                title: l10n.securityChangePassword,
                subtitle: l10n.securityChangePasswordSubtitle,
                onTap: () => _openChangePasswordSheet(context),
              ),
              SettingSwitchTile(
                icon: Icons.shield_outlined,
                title: l10n.securityTwoFactor,
                subtitle: l10n.securityTwoFactorBody,
                value: prefs.twoFactorEnabled,
                onChanged: (v) => _toggleTwoFactor(ref, context, v),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          SettingSection(
            title: l10n.securitySessions,
            children: [
              SettingTile(
                icon: Icons.devices_rounded,
                title: l10n.securityThisDevice,
                subtitle: thisDeviceLabel,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          SettingSection(
            title: l10n.securityHistory,
            children: [
              for (final entry in history)
                SettingTile(
                  icon: Icons.history_rounded,
                  title: entry,
                ),
            ],
          ),
        ],
      ),
    );
  }

  String _humanWhen(DateTime d) {
    final now = DateTime.now();
    final diff = now.difference(d);
    if (diff.inHours < 1) return '${diff.inMinutes.clamp(1, 60)} min ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}

// ---------------------------------------------------------------------------
// Change-password bottom sheet — mock save
// ---------------------------------------------------------------------------

Future<void> _openChangePasswordSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppColors.surfaceElevated,
    isScrollControlled: true,
    builder: (_) => const _ChangePasswordSheet(),
  );
}

class _ChangePasswordSheet extends ConsumerStatefulWidget {
  const _ChangePasswordSheet();

  @override
  ConsumerState<_ChangePasswordSheet> createState() =>
      _ChangePasswordSheetState();
}

class _ChangePasswordSheetState extends ConsumerState<_ChangePasswordSheet> {
  final _form = GlobalKey<FormState>();
  final _current = TextEditingController();
  final _new = TextEditingController();
  final _confirm = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _current.dispose();
    _new.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    setState(() => _saving = true);
    // Mock save — real Supabase mode will call `auth.updateUser(password: …)`.
    await Future<void>.delayed(const Duration(milliseconds: 500));
    if (!mounted) return;
    setState(() => _saving = false);
    final l10n = AppLocalizations.of(context);
    Navigator.of(context).pop();
    context.showSnack(l10n.changePasswordSuccess);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final inset = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.lg,
        AppSpacing.lg,
        AppSpacing.lg + inset,
      ),
      child: Form(
        key: _form,
        autovalidateMode: AutovalidateMode.onUserInteraction,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l10n.changePasswordTitle, style: AppTypography.h3),
            const SizedBox(height: AppSpacing.lg),
            AppTextField(
              controller: _current,
              label: l10n.changePasswordCurrent,
              prefixIcon: Icons.lock_outline_rounded,
              obscureText: true,
              validator: (v) => Validators.password(v, l10n),
            ),
            const SizedBox(height: AppSpacing.md),
            AppTextField(
              controller: _new,
              label: l10n.changePasswordNew,
              prefixIcon: Icons.lock_outline_rounded,
              obscureText: true,
              validator: (v) => Validators.password(v, l10n),
            ),
            const SizedBox(height: AppSpacing.md),
            AppTextField(
              controller: _confirm,
              label: l10n.changePasswordConfirm,
              prefixIcon: Icons.lock_outline_rounded,
              obscureText: true,
              validator: (v) =>
                  Validators.confirmPassword(v, _new.text, l10n),
            ),
            const SizedBox(height: AppSpacing.lg),
            AppButton(
              label: l10n.changePasswordSubmit,
              size: AppButtonSize.large,
              isLoading: _saving,
              onPressed: _saving ? null : _submit,
            ),
          ],
        ),
      ),
    );
  }
}
