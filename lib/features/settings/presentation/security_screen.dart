import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../core/errors/failures.dart';
import '../../../core/utils/extensions.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/app_scaffold.dart';
import '../../auth/data/auth_repository.dart';
import '../../auth/presentation/providers/auth_provider.dart';
import '../../profile_setup/presentation/providers/profile_provider.dart';
import '../data/settings_repository.dart';
import '../domain/settings_models.dart';
import 'providers/settings_providers.dart';
import 'widgets/setting_widgets.dart';

class SecurityScreen extends ConsumerStatefulWidget {
  const SecurityScreen({super.key});

  @override
  ConsumerState<SecurityScreen> createState() => _SecurityScreenState();
}

class _SecurityScreenState extends ConsumerState<SecurityScreen> {
  bool _linking = false;

  Future<void> _toggleTwoFactor(bool value) async {
    final profile = ref.read(currentProfileProvider).asData?.value;
    if (profile == null) return;
    final repo = ref.read(settingsRepositoryProvider);
    final current =
        ref.read(privacyPrefsProvider).asData?.value ?? const PrivacyPrefs();
    await repo.updatePrivacyPrefs(
      profile.userId,
      current.copyWith(twoFactorEnabled: value),
    );
    if (!mounted) return;
    context.showSnack(AppLocalizations.of(context).savedSnack);
  }

  /// Triggers Supabase's voluntary identity-linking flow for [provider].
  /// On `identity_already_exists`, surfaces a humane sheet pointing
  /// the user to the right sign-in method instead of leaking the raw
  /// error.
  Future<void> _link(OAuthProvider provider) async {
    if (_linking) return;
    setState(() => _linking = true);
    final ok = await ref
        .read(authControllerProvider.notifier)
        .linkIdentity(provider);
    if (!mounted) return;
    setState(() => _linking = false);
    final l10n = AppLocalizations.of(context);
    if (ok) {
      context.showSnack(l10n.securityLinkSuccess);
      return;
    }
    final err = ref.read(authControllerProvider).error;
    if (err is OAuthCancelledFailure) return;
    if (err is Failure && err.code == 'identity_already_exists') {
      await _showEmailAlreadyUsedSheet();
      return;
    }
    final msg = err is Failure ? err.message : l10n.securityLinkFailed;
    context.showSnack(msg);
  }

  /// "Un compte existe déjà avec cette adresse." sheet — the only
  /// non-OK linking outcome that gets a dedicated UX (vs a snack).
  /// Points the user at the alternative sign-in methods instead of
  /// leaking the raw Supabase string.
  Future<void> _showEmailAlreadyUsedSheet() async {
    final l10n = AppLocalizations.of(context);
    await showCupertinoModalPopup<void>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: Text(l10n.securityEmailInUseTitle),
        message: Text(l10n.securityEmailInUseBody),
        actions: [
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l10n.commonDone),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final prefs =
        ref.watch(privacyPrefsProvider).asData?.value ?? const PrivacyPrefs();
    final identities =
        Supabase.instance.client.auth.currentUser?.identities ?? const [];
    final providers = identities
        .map((i) => i.provider.toLowerCase())
        .whereType<String>()
        .toSet();
    final hasApple = providers.contains('apple');
    final hasGoogle = providers.contains('google');
    final hasEmail = providers.contains('email');

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
            title: l10n.securityLinkedAccounts,
            children: [
              _LinkedAccountTile(
                icon: Icons.mail_outline_rounded,
                title: l10n.securityProviderEmail,
                linked: hasEmail,
                onTap: null, // email is linked at signup, no manual flow
              ),
              _LinkedAccountTile(
                icon: Icons.apple_rounded,
                title: l10n.securityProviderApple,
                linked: hasApple,
                onTap: hasApple || _linking
                    ? null
                    : () => _link(OAuthProvider.apple),
              ),
              _LinkedAccountTile(
                icon: Icons.account_circle_outlined,
                title: l10n.securityProviderGoogle,
                linked: hasGoogle,
                onTap: hasGoogle || _linking
                    ? null
                    : () => _link(OAuthProvider.google),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          SettingSection(
            title: l10n.securityTitle,
            children: [
              SettingSwitchTile(
                icon: Icons.shield_outlined,
                title: l10n.securityTwoFactor,
                subtitle: l10n.securityTwoFactorBody,
                value: prefs.twoFactorEnabled,
                onChanged: _toggleTwoFactor,
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
                subtitle: l10n.securitySignInEntry(
                  l10n.securityThisDevice,
                  _humanWhen(DateTime.now()),
                ),
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

/// One row of the "Linked accounts" section. Shows a "Linked"
/// confirmation pill on the right when the provider is attached,
/// otherwise lets the user tap to start the link flow.
class _LinkedAccountTile extends StatelessWidget {
  const _LinkedAccountTile({
    required this.icon,
    required this.title,
    required this.linked,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final bool linked;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return SettingTile(
      icon: icon,
      title: title,
      subtitle:
          linked ? l10n.securityProviderLinked : l10n.securityProviderTapToLink,
      onTap: onTap,
      trailing: linked
          ? const Icon(
              Icons.check_circle_rounded,
              color: AppColors.brandPink,
            )
          : (onTap == null
              ? null
              : const Icon(
                  Icons.chevron_right_rounded,
                  color: AppColors.textTertiary,
                )),
    );
  }
}
