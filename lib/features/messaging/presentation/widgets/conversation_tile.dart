import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_spacing.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../profile_setup/data/profile_repository.dart';
import '../../domain/conversation.dart';

/// One row of the inbox. Shows the matched peer's photo, name, last
/// message preview, the time of the last message, and an unread badge.
class ConversationTile extends ConsumerWidget {
  const ConversationTile({
    super.key,
    required this.conversation,
    required this.onTap,
  });

  final Conversation conversation;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: AppRadius.brLg,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
          child: Row(
            children: [
              _PeerAvatar(photoUrl: conversation.peerPrimaryPhotoUrl),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            conversation.peerFirstName ?? '—',
                            style: AppTypography.bodyStrong,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (conversation.lastMessageAt != null)
                          Text(
                            _humanizeTime(
                              conversation.lastMessageAt!,
                              l10n,
                            ),
                            style: AppTypography.caption.copyWith(
                              color: AppColors.textTertiary,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            conversation.lastMessagePreview ??
                                l10n.conversationLockedSelf,
                            style: AppTypography.body.copyWith(
                              color: conversation.unreadCount > 0
                                  ? AppColors.textPrimary
                                  : AppColors.textSecondary,
                              fontWeight: conversation.unreadCount > 0
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (conversation.unreadCount > 0) ...[
                          const SizedBox(width: AppSpacing.xs),
                          _UnreadBadge(count: conversation.unreadCount),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PeerAvatar extends ConsumerWidget {
  const _PeerAvatar({required this.photoUrl});

  final String? photoUrl;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const size = 52.0;
    if (photoUrl == null) {
      return Container(
        width: size,
        height: size,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          gradient: AppColors.brandGradient,
        ),
        child: const Center(
          child: Icon(Icons.person_rounded, color: Colors.white),
        ),
      );
    }
    return FutureBuilder(
      future: ref.read(profileRepositoryProvider).getPhotoBytes(photoUrl!),
      builder: (context, snap) {
        if (snap.data != null) {
          return Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.hairline),
              image: DecorationImage(
                image: MemoryImage(snap.data!),
                fit: BoxFit.cover,
              ),
            ),
          );
        }
        return Container(
          width: size,
          height: size,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            gradient: AppColors.brandGradient,
          ),
          child: const Center(
            child: Icon(Icons.person_rounded, color: Colors.white),
          ),
        );
      },
    );
  }
}

class _UnreadBadge extends StatelessWidget {
  const _UnreadBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        gradient: AppColors.brandGradient,
        borderRadius: AppRadius.brPill,
      ),
      child: Text(
        l10n.messagesUnreadBadge(count),
        style: AppTypography.caption.copyWith(
          color: Colors.white,
          fontWeight: FontWeight.w700,
          fontSize: 11,
        ),
      ),
    );
  }
}

String _humanizeTime(DateTime when, AppLocalizations l10n) {
  final diff = DateTime.now().difference(when);
  if (diff.inMinutes < 1) return l10n.messageTimeJustNow;
  if (diff.inMinutes < 60) return l10n.messageTimeMinutes(diff.inMinutes);
  if (diff.inHours < 24) return l10n.messageTimeHours(diff.inHours);
  if (diff.inDays == 1) return l10n.messageTimeYesterday;
  return l10n.messageTimeDaysAgo(diff.inDays);
}
