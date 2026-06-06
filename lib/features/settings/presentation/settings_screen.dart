import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/app_routes.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../core/config/feature_flags.dart';
import '../../../core/utils/extensions.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/app_scaffold.dart';
import '../../auth/presentation/providers/auth_provider.dart';
import '../../identity/data/identity_repository.dart';
import '../../identity/domain/identity_verification_status.dart';
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
      context.showSnack(l10n.errorGeneric);
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
              // Identity-verification tile — Phase 5 + UX iteration.
              //
              // Five visual states keyed off the latest
              // identity_verifications row's `status`. The green
              // check is shown EXCLUSIVELY for `approved` (i.e. a
              // real Didit verdict), never for grandfather accounts
              // (no row → falls into the "À vérifier" branch). This
              // matches the audit-honesty invariant : if Settings
              // says "Identité vérifiée ✓" with a green check, the
              // user *really* went through Didit.
              //
              // Hidden entirely when the gate is disabled via
              // `.env IDENTITY_GATE=false` so we never advertise a
              // dormant feature.
              // TODO(i18n-identity): localise strings.
              if (FeatureFlags.requireIdentityVerification)
                Consumer(
                  builder: (context, ref, _) {
                    final user = ref.watch(currentUserProvider);
                    if (user == null) return const SizedBox.shrink();
                    final latest = ref
                        .watch(latestIdentityVerificationProvider(user.id))
                        .asData
                        ?.value;
                    final tile = _identityTileFor(latest?.status);
                    return SettingTile(
                      icon: tile.icon,
                      title: 'Vérification d\'identité',
                      subtitle: tile.subtitle,
                      trailing: Icon(
                        tile.trailingIcon,
                        color: tile.trailingColor,
                        size: 22,
                      ),
                      onTap: () => context.pushNamed(
                        AppRoute.identityVerification.name,
                      ),
                    );
                  },
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

// ── Identity-verification tile state mapping ─────────────────────
//
// Helper kept private to this file — the Phase 4 IdentityVerification
// screen has its own (richer) palette table for the same status enum,
// but the Settings tile only needs a 5-row table with a subtitle +
// trailing icon (no large status card body).
//
// `approved` (the only "Didit-verified" branch) gets the green
// check. Every other branch — including the `null` row that covers
// "never started" AND grandfather accounts — gets an amber or red
// glyph so the visual hierarchy stays honest.

class _IdentityTileState {
  const _IdentityTileState({
    required this.icon,
    required this.subtitle,
    required this.trailingIcon,
    required this.trailingColor,
  });
  final IconData icon;
  final String subtitle;
  final IconData trailingIcon;
  final Color trailingColor;
}

_IdentityTileState _identityTileFor(IdentityVerificationStatus? s) {
  switch (s) {
    case IdentityVerificationStatus.approved:
      return const _IdentityTileState(
        icon: Icons.verified_user_outlined,
        subtitle: 'Identité vérifiée',
        trailingIcon: Icons.check_circle_rounded,
        trailingColor: AppColors.success,
      );
    case IdentityVerificationStatus.pending:
    case IdentityVerificationStatus.inReview:
      return const _IdentityTileState(
        icon: Icons.verified_user_outlined,
        subtitle: 'Vérification en cours',
        trailingIcon: Icons.hourglass_top_rounded,
        trailingColor: AppColors.warning,
      );
    case IdentityVerificationStatus.rejected:
      return const _IdentityTileState(
        icon: Icons.verified_user_outlined,
        subtitle: 'Vérification refusée',
        trailingIcon: Icons.error_outline_rounded,
        trailingColor: AppColors.error,
      );
    case IdentityVerificationStatus.expired:
      return const _IdentityTileState(
        icon: Icons.verified_user_outlined,
        subtitle: 'Session expirée, recommencer',
        trailingIcon: Icons.timer_off_outlined,
        trailingColor: AppColors.warning,
      );
    case null:
      // Covers BOTH "never started" AND grandfather accounts. No
      // green check, no false-positive verification claim.
      return const _IdentityTileState(
        icon: Icons.verified_user_outlined,
        subtitle: 'Vérifier mon identité',
        trailingIcon: Icons.error_outline_rounded,
        trailingColor: AppColors.warning,
      );
  }
}
