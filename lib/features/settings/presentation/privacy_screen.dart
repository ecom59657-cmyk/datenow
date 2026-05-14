import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../core/utils/extensions.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/app_scaffold.dart';
import '../../profile_setup/presentation/providers/profile_provider.dart';
import '../data/settings_repository.dart';
import '../domain/settings_models.dart';
import 'providers/settings_providers.dart';
import 'widgets/setting_widgets.dart';

class PrivacyScreen extends ConsumerWidget {
  const PrivacyScreen({super.key});

  Future<void> _update(
    WidgetRef ref,
    BuildContext context,
    PrivacyPrefs Function(PrivacyPrefs) f,
  ) async {
    final profile = ref.read(currentProfileProvider).asData?.value;
    if (profile == null) return;
    final repo = ref.read(settingsRepositoryProvider);
    final current =
        ref.read(privacyPrefsProvider).asData?.value ?? const PrivacyPrefs();
    await repo.updatePrivacyPrefs(profile.userId, f(current));
    if (!context.mounted) return;
    context.showSnack(AppLocalizations.of(context).savedSnack);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final prefs =
        ref.watch(privacyPrefsProvider).asData?.value ?? const PrivacyPrefs();

    return AppScaffold(
      appBar: AppBar(
        title: Text(l10n.privacyTitle),
        leading: const BackButton(),
      ),
      body: ListView(
        padding: const EdgeInsets.only(top: AppSpacing.md, bottom: 64),
        children: [
          Text(
            l10n.privacySubtitle,
            style:
                AppTypography.body.copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: AppSpacing.lg),
          SettingSection(
            title: l10n.privacyTitle,
            children: [
              SettingSwitchTile(
                icon: Icons.visibility_outlined,
                title: l10n.privacyShowOnline,
                subtitle: l10n.privacyShowOnlineBody,
                value: prefs.showOnline,
                onChanged: (v) => _update(
                  ref,
                  context,
                  (p) => p.copyWith(showOnline: v),
                ),
              ),
              SettingSwitchTile(
                icon: Icons.no_photography_outlined,
                title: l10n.privacyBlockScreenshots,
                subtitle: l10n.privacyBlockScreenshotsBody,
                value: prefs.blockScreenshots,
                onChanged: (v) => _update(
                  ref,
                  context,
                  (p) => p.copyWith(blockScreenshots: v),
                ),
              ),
              SettingSwitchTile(
                icon: Icons.bar_chart_rounded,
                title: l10n.privacyShareUsage,
                subtitle: l10n.privacyShareUsageBody,
                value: prefs.shareUsageData,
                onChanged: (v) => _update(
                  ref,
                  context,
                  (p) => p.copyWith(shareUsageData: v),
                ),
              ),
              SettingSwitchTile(
                icon: Icons.campaign_outlined,
                title: l10n.privacyMarketing,
                subtitle: l10n.privacyMarketingBody,
                value: prefs.marketingConsent,
                onChanged: (v) => _update(
                  ref,
                  context,
                  (p) => p.copyWith(marketingConsent: v),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
