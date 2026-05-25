import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/app_routes.dart';
import '../../../app/scaffold/active_tab.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/app_scaffold.dart';
import '../../../shared/widgets/glass_card.dart';
import '../../../shared/widgets/loading_indicator.dart';
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
  @override
  int get tabIndex => 2; // Home=0, Discover=1, Messages=2, Profile=3

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final inbox = ref.watch(inboxProvider);

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
            error: (e, _) => _EmptyCard(
              icon: Icons.error_outline_rounded,
              message: '$e',
            ),
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
