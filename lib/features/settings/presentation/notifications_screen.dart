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

class NotificationsScreen extends ConsumerWidget {
  const NotificationsScreen({super.key});

  Future<void> _update(
    WidgetRef ref,
    BuildContext context,
    NotificationPrefs Function(NotificationPrefs) f,
  ) async {
    final profile = ref.read(currentProfileProvider).asData?.value;
    if (profile == null) return;
    final repo = ref.read(settingsRepositoryProvider);
    final current = ref.read(notificationPrefsProvider).asData?.value ??
        const NotificationPrefs();
    await repo.updateNotificationPrefs(profile.userId, f(current));
    if (!context.mounted) return;
    context.showSnack(AppLocalizations.of(context).savedSnack);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final prefs = ref.watch(notificationPrefsProvider).asData?.value ??
        const NotificationPrefs();

    return AppScaffold(
      appBar: AppBar(
        title: Text(l10n.notificationsTitle),
        leading: const BackButton(),
      ),
      body: ListView(
        padding: const EdgeInsets.only(top: AppSpacing.md, bottom: 64),
        children: [
          Text(
            l10n.notificationsSubtitle,
            style:
                AppTypography.body.copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: AppSpacing.lg),
          SettingSection(
            title: l10n.notificationsTitle,
            children: [
              SettingSwitchTile(
                icon: Icons.favorite_outline_rounded,
                title: l10n.notifPushMatch,
                value: prefs.pushNewMatch,
                onChanged: (v) => _update(
                  ref,
                  context,
                  (p) => p.copyWith(pushNewMatch: v),
                ),
              ),
              SettingSwitchTile(
                icon: Icons.explore_outlined,
                title: l10n.notifPushSuggestion,
                value: prefs.pushSuggestions,
                onChanged: (v) => _update(
                  ref,
                  context,
                  (p) => p.copyWith(pushSuggestions: v),
                ),
              ),
              SettingSwitchTile(
                icon: Icons.chat_bubble_outline_rounded,
                title: l10n.notifPushMessage,
                value: prefs.pushMessages,
                onChanged: (v) => _update(
                  ref,
                  context,
                  (p) => p.copyWith(pushMessages: v),
                ),
              ),
              SettingSwitchTile(
                icon: Icons.calendar_view_week_rounded,
                title: l10n.notifEmailDigest,
                value: prefs.emailWeeklyDigest,
                onChanged: (v) => _update(
                  ref,
                  context,
                  (p) => p.copyWith(emailWeeklyDigest: v),
                ),
              ),
              SettingSwitchTile(
                icon: Icons.campaign_outlined,
                title: l10n.notifEmailMarketing,
                value: prefs.emailMarketing,
                onChanged: (v) => _update(
                  ref,
                  context,
                  (p) => p.copyWith(emailMarketing: v),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
