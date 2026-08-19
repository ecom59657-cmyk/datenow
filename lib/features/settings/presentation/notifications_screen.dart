import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../core/notifications/push_notifications_service.dart';
import '../../../core/utils/extensions.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/app_scaffold.dart';
import '../../profile_setup/presentation/providers/profile_provider.dart';
import '../data/settings_repository.dart';
import '../domain/settings_models.dart';
import 'providers/settings_providers.dart';
import 'widgets/setting_widgets.dart';

class NotificationsScreen extends ConsumerStatefulWidget {
  const NotificationsScreen({super.key});

  @override
  ConsumerState<NotificationsScreen> createState() =>
      _NotificationsScreenState();
}

class _NotificationsScreenState extends ConsumerState<NotificationsScreen> {
  AuthorizationStatus? _iosStatus;
  bool _registering = false;

  @override
  void initState() {
    super.initState();
    _refreshStatus();
  }

  Future<void> _refreshStatus() async {
    final status =
        await PushNotificationsService.instance.currentAuthorizationStatus();
    if (!mounted) return;
    setState(() => _iosStatus = status);
  }

  Future<void> _tapEnableIosPush() async {
    final l10n = AppLocalizations.of(context);
    final push = PushNotificationsService.instance;
    // Firebase isn't wired up — surface a debug-friendly message so the
    // user knows it's a config issue, not a user permission issue.
    if (!push.isAvailable) {
      context.showSnack(l10n.pushDebugNoFirebase);
      return;
    }
    final current = _iosStatus ?? await push.currentAuthorizationStatus();
    // Already denied at the iOS system level → can't re-prompt, send
    // the user to Settings.
    if (current == AuthorizationStatus.denied) {
      await openAppSettings();
      await _refreshStatus();
      return;
    }
    setState(() => _registering = true);
    final ok = await push.requestPermissionAndRegister();
    if (!mounted) return;
    setState(() => _registering = false);
    await _refreshStatus();
    if (!mounted) return;
    context.showSnack(
      ok ? l10n.pushDebugEnabledOk : l10n.pushDebugEnabledKo,
    );
  }

  String _iosStatusLabel(AppLocalizations l10n) {
    switch (_iosStatus) {
      case AuthorizationStatus.authorized:
        return l10n.pushDebugStatusAuthorized;
      case AuthorizationStatus.provisional:
        return l10n.pushDebugStatusAuthorized;
      case AuthorizationStatus.denied:
        return l10n.pushDebugStatusDenied;
      case AuthorizationStatus.notDetermined:
        return l10n.pushDebugStatusNotDetermined;
      case null:
        return PushNotificationsService.instance.isAvailable
            ? '…'
            : l10n.pushDebugStatusUnavailable;
    }
  }

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
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final prefs = ref.watch(notificationPrefsProvider).asData?.value ??
        const NotificationPrefs();
    final isAuthorized = _iosStatus == AuthorizationStatus.authorized ||
        _iosStatus == AuthorizationStatus.provisional;

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
            title: l10n.pushDebugSectionTitle,
            children: [
              SettingTile(
                icon: Icons.notifications_active_rounded,
                title: l10n.pushDebugEnableIos,
                subtitle: _iosStatusLabel(l10n),
                onTap: (isAuthorized || _registering) ? null : _tapEnableIosPush,
                trailing: _registering
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : isAuthorized
                        ? const Icon(
                            Icons.check_circle_rounded,
                            color: AppColors.bordeaux,
                          )
                        : null,
              ),
            ],
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
