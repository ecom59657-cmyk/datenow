import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../app/router/app_routes.dart';
import '../../../app/scaffold/active_tab.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../core/notifications/push_notifications_service.dart';
import '../../../core/utils/logger.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/app_button.dart';
import '../../../shared/widgets/app_scaffold.dart';
import '../../../shared/widgets/glass_card.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../auth/presentation/providers/auth_provider.dart';
import 'providers/messaging_providers.dart';
import 'widgets/conversation_tile.dart';

/// The Messages inbox. Lists every conversation the current user has —
/// each one is the result of a confirmed mutual match (no other path
/// creates a conversation row, see `MessagingRepository.ensureConversation`).
///
/// Lives as the root of the Messages tab in [StatefulShellRoute] — no
/// back arrow, scroll auto-resets to the top whenever the user returns.
class InboxScreen extends ConsumerStatefulWidget {
  const InboxScreen({super.key});

  @override
  ConsumerState<InboxScreen> createState() => _InboxScreenState();
}

class _InboxScreenState extends ConsumerState<InboxScreen>
    with TabScrollResetMixin {
  static const _pushAskedFlag = 'push_perm_asked';

  @override
  int get tabIndex => 2; // Home=0, Discover=1, Messages=2, Profile=3

  @override
  void initState() {
    super.initState();
    // One-shot permission nudge on the first ever Messages visit.
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeAskPush());
  }

  /// Shows the in-app push permission sheet when:
  ///   • Firebase is up (GoogleService-Info.plist bundled), AND
  ///   • iOS permission is still `notDetermined` (we never asked OR the
  ///     user reinstalled the app), AND
  ///   • the user has no row in `device_tokens` yet.
  ///
  /// The SharedPreferences `push_asked_flag` is consulted but a missing
  /// token always trumps the flag — that way a user who tapped "Plus
  /// tard" once but never registered still gets nudged on later visits
  /// (until they explicitly decline at the iOS system prompt, after
  /// which the iOS status becomes `denied` and we stop nudging).
  Future<void> _maybeAskPush() async {
    if (!mounted) return;
    final push = PushNotificationsService.instance;
    if (!push.isAvailable) {
      const AppLogger('Push').info(
        'inbox: skip sheet — Firebase not ready '
        '(lastInitError=${'…check Push logs at startup'})',
      );
      return;
    }
    final status = await push.currentAuthorizationStatus();
    // Already granted → no need to show our sheet again.
    if (status == AuthorizationStatus.authorized ||
        status == AuthorizationStatus.provisional) {
      // But check that the token landed in device_tokens — Apple may
      // have rotated it, or the previous upsert may have failed.
      final hasToken = await push.hasRegisteredTokenForCurrentUser();
      if (!hasToken) {
        const AppLogger('Push').info(
          'inbox: permission granted but no token row — re-registering',
        );
        // ignore: discarded_futures
        push.requestPermissionAndRegister();
      }
      return;
    }
    // User explicitly denied at the system prompt — we can't re-show
    // the OS dialog, so just stop nudging.
    if (status == AuthorizationStatus.denied) return;
    // status == notDetermined (or null when getNotificationSettings
    // failed). Show the in-app explainer + button.
    if (!mounted) return;
    final accepted = await showModalBottomSheet<bool>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => const _PushPermissionSheet(),
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_pushAskedFlag, true);
    if (accepted == true) {
      await push.requestPermissionAndRegister();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final inbox = ref.watch(inboxProvider);
    // Self id resolves the peer of each conversation so its avatar can open
    // the matched-profile card. Every inbox row is a confirmed mutual match.
    final selfId = ref.watch(currentUserProvider)?.id;

    return AppScaffold(
      appBar: AppBar(
        title: Text(l10n.messagesTitle),
        automaticallyImplyLeading: false,
      ),
      body: ListView(
        controller: tabScrollController,
        padding: const EdgeInsets.only(top: AppSpacing.md, bottom: 64),
        children: [
          Text(
            l10n.messagesSubtitle,
            style:
                AppTypography.body.copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: AppSpacing.lg),
          inbox.when(
            loading: () => const Padding(
              padding: EdgeInsets.all(AppSpacing.xl),
              child: LoadingIndicator(),
            ),
            // Never surface a raw `PostgrestException(...)` to the user.
            // The most common cause is the schema cache not yet seeing
            // `public.conversations` (the PGRST205 incident on TestFlight),
            // and in every failure mode "no conversations to show" is
            // the right product behaviour. Log for debug, present the
            // same premium empty card as the truly-empty path.
            error: (e, st) {
              const AppLogger('Inbox').warn('inbox stream error: $e\n$st');
              return _EmptyCard(
                icon: Icons.chat_bubble_outline_rounded,
                title: l10n.messagesEmptyTitle,
                message: l10n.messagesEmptyBody,
              );
            },
            data: (list) {
              if (list.isEmpty) {
                return _EmptyCard(
                  icon: Icons.chat_bubble_outline_rounded,
                  title: l10n.messagesEmptyTitle,
                  message: l10n.messagesEmptyBody,
                );
              }
              return GlassCard(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    for (final (i, c) in list.indexed) ...[
                      ConversationTile(
                        conversation: c,
                        onTap: () => context.pushNamed(
                          AppRoute.conversation.name,
                          pathParameters: {'id': c.id},
                        ),
                        onAvatarTap: selfId == null
                            ? null
                            : () => context.pushNamed(
                                  AppRoute.matchedProfile.name,
                                  pathParameters: {
                                    'userId': c.peerIdFor(selfId)
                                  },
                                ),
                      ),
                      if (i < list.length - 1)
                        const Divider(
                          color: AppColors.hairlineSoft,
                          height: 1,
                          indent: AppSpacing.md,
                          endIndent: AppSpacing.md,
                        ),
                    ],
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _EmptyCard extends StatelessWidget {
  const _EmptyCard({
    required this.icon,
    this.title,
    required this.message,
  });

  final IconData icon;
  final String? title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(AppSpacing.sm),
            decoration: BoxDecoration(
              color: AppColors.violetSoft,
              borderRadius: AppRadius.brSm,
            ),
            child: Icon(icon, color: AppColors.brandViolet),
          ),
          const SizedBox(height: AppSpacing.md),
          if (title != null) ...[
            Text(title!, style: AppTypography.h3),
            const SizedBox(height: AppSpacing.xs),
          ],
          Text(
            message,
            style:
                AppTypography.body.copyWith(color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }
}

/// In-app prompt shown once on the first ever Messages tab visit
/// (tracked in SharedPreferences). Tapping Activer pops the sheet with
/// `true` and the parent runs `requestPermissionAndRegister()`. Tapping
/// Plus tard pops with `false` and we never ask again from the inbox.
class _PushPermissionSheet extends StatelessWidget {
  const _PushPermissionSheet();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.lg,
          AppSpacing.lg,
          AppSpacing.sm,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              width: 80,
              height: 80,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: AppColors.brandGradient,
                boxShadow: [
                  BoxShadow(
                    color: AppColors.brandPink.withValues(alpha: 0.4),
                    blurRadius: 24,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: const Icon(
                Icons.notifications_active_rounded,
                color: Colors.white,
                size: 36,
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            Text(
              l10n.pushPermissionTitle,
              textAlign: TextAlign.center,
              style: AppTypography.h2,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              l10n.pushPermissionBody,
              textAlign: TextAlign.center,
              style:
                  AppTypography.body.copyWith(color: AppColors.textSecondary),
            ),
            const SizedBox(height: AppSpacing.lg),
            AppButton(
              label: l10n.pushPermissionEnable,
              icon: Icons.notifications_rounded,
              size: AppButtonSize.large,
              onPressed: () => Navigator.of(context).pop(true),
            ),
            const SizedBox(height: AppSpacing.sm),
            AppButton(
              label: l10n.pushPermissionLater,
              variant: AppButtonVariant.secondary,
              onPressed: () => Navigator.of(context).pop(false),
            ),
            const SizedBox(height: AppSpacing.sm),
          ],
        ),
      ),
    );
  }
}
