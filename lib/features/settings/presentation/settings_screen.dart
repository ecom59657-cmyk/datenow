import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/app_routes.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../core/utils/extensions.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/app_scaffold.dart';
import '../../auth/presentation/providers/auth_provider.dart';
import 'widgets/destructive_dialog.dart';
import 'widgets/setting_widgets.dart';

/// Main entry to everything account-related. Every tile here is either a
/// navigation entry to a real sub-screen or a guarded action — no dead taps.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  Future<void> _confirmSignOut(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDestructiveConfirm(
      context: context,
      title: l10n.signOutConfirmTitle,
      body: l10n.signOutConfirmBody,
      confirmLabel: l10n.signOutConfirmAction,
      isDangerous: false,
    );
    if (!confirmed || !context.mounted) return;
    await ref.read(authControllerProvider.notifier).signOut();
    // Router redirect on auth-state change brings us back to /auth automatically.
    if (!context.mounted) return;
    context.showSnack(l10n.signedOutSnack);
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDestructiveConfirm(
      context: context,
      title: l10n.deleteAccountConfirmTitle,
      body: l10n.deleteAccountConfirmBody,
      confirmLabel: l10n.deleteAccountConfirmAction,
    );
    if (!confirmed || !context.mounted) return;
    try {
      await ref.read(authControllerProvider.notifier).deleteAccount();
      if (!context.mounted) return;
      context.showSnack(l10n.deletedAccountSnack);
    } catch (e) {
      if (!context.mounted) return;
      // Surface the failure so the user knows nothing happened and can
      // retry or contact support — silently sliding back to settings
      // after a "delete forever" tap would be misleading.
      context.showSnack('$e');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);

    return AppScaffold(
      appBar: AppBar(
        title: Text(l10n.settingsTitle),
        leading: const BackButton(),
      ),
      body: ListView(
        padding: const EdgeInsets.only(top: AppSpacing.md, bottom: 64),
        children: [
          SettingSection(
            title: l10n.settingsProfileSection,
            children: [
              SettingTile(
                icon: Icons.person_outline_rounded,
                title: l10n.profilePersonalEntry,
                subtitle: l10n.profilePersonalSubtitle,
                onTap: () => context.pushNamed(AppRoute.editProfile.name),
              ),
              SettingTile(
                icon: Icons.tune_rounded,
                title: l10n.profilePreferences,
                subtitle: l10n.profilePreferencesSubtitle,
                onTap: () =>
                    context.pushNamed(AppRoute.editPreferences.name),
              ),
              SettingTile(
                icon: Icons.photo_library_outlined,
                title: l10n.profilePhotos,
                subtitle: l10n.profilePhotosSubtitle,
                onTap: () => context.pushNamed(AppRoute.editPhotos.name),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          SettingSection(
            title: l10n.settingsAccountSection,
            children: [
              SettingTile(
                icon: Icons.notifications_active_outlined,
                title: l10n.notificationsTitle,
                subtitle: l10n.notificationsSubtitle,
                onTap: () =>
                    context.pushNamed(AppRoute.settingsNotifications.name),
              ),
              SettingTile(
                icon: Icons.shield_outlined,
                title: l10n.privacyTitle,
                subtitle: l10n.privacySubtitle,
                onTap: () =>
                    context.pushNamed(AppRoute.settingsPrivacy.name),
              ),
              SettingTile(
                icon: Icons.lock_outline_rounded,
                title: l10n.settingsSecurity,
                subtitle: l10n.settingsSecuritySubtitle,
                onTap: () =>
                    context.pushNamed(AppRoute.settingsSecurity.name),
              ),
              SettingTile(
                icon: Icons.person_off_outlined,
                title: l10n.settingsBlocked,
                subtitle: l10n.settingsBlockedSubtitle,
                onTap: () =>
                    context.pushNamed(AppRoute.settingsBlocked.name),
              ),
              SettingTile(
                icon: Icons.workspace_premium_rounded,
                title: l10n.settingsSubscription,
                subtitle: l10n.settingsSubscriptionSubtitle,
                onTap: () =>
                    context.pushNamed(AppRoute.settingsSubscription.name),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          SettingSection(
            title: l10n.settingsSupportSection,
            children: [
              SettingTile(
                icon: Icons.help_outline_rounded,
                title: l10n.settingsHelp,
                subtitle: l10n.settingsHelpSubtitle,
                onTap: () => context.pushNamed(AppRoute.settingsHelp.name),
              ),
              SettingTile(
                icon: Icons.description_outlined,
                title: l10n.settingsTerms,
                subtitle: l10n.settingsTermsSubtitle,
                onTap: () => context.pushNamed(AppRoute.settingsTerms.name),
              ),
              SettingTile(
                icon: Icons.privacy_tip_outlined,
                title: l10n.settingsPrivacyPolicy,
                subtitle: l10n.settingsPrivacyPolicySubtitle,
                onTap: () => context
                    .pushNamed(AppRoute.settingsPrivacyPolicy.name),
              ),
              // Dev-only diagnostic hub — compiled out of release builds
              // entirely (kDebugMode is a const false in release).
              if (kDebugMode)
                SettingTile(
                  icon: Icons.bug_report_outlined,
                  title: 'Debug · DateNow',
                  subtitle:
                      'Matching / Call / Reveal — outils de test (debug only)',
                  onTap: () =>
                      context.pushNamed(AppRoute.debugDateNow.name),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          SettingSection(
            title: l10n.settingsDangerSection,
            children: [
              SettingTile(
                icon: Icons.logout_rounded,
                title: l10n.settingsSignOut,
                subtitle: l10n.settingsSignOutSubtitle,
                onTap: () => _confirmSignOut(context, ref),
              ),
              SettingTile(
                icon: Icons.delete_forever_outlined,
                title: l10n.settingsDeleteAccount,
                subtitle: l10n.settingsDeleteAccountSubtitle,
                danger: true,
                onTap: () => _confirmDelete(context, ref),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
