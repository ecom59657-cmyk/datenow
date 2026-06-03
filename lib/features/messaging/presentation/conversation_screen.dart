import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/app_routes.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../core/utils/extensions.dart';
import '../../../core/utils/logger.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/app_scaffold.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../auth/presentation/providers/auth_provider.dart';
import '../../profile_setup/data/profile_repository.dart';
import '../../safety/presentation/report_sheet.dart';
import '../data/messaging_repository.dart';
import '../domain/conversation.dart';
import '../domain/message.dart';
import 'providers/messaging_providers.dart';
import 'widgets/message_bubble.dart';
import 'widgets/message_input.dart';

/// The chat screen for a single [Conversation]. Receives the id via the
/// route param (`/messages/:id`) and resolves the conversation against
/// the inbox stream so we always render the latest peer info.
class ConversationScreen extends ConsumerStatefulWidget {
  const ConversationScreen({super.key, required this.conversationId});

  final String conversationId;

  @override
  ConsumerState<ConversationScreen> createState() =>
      _ConversationScreenState();
}

class _ConversationScreenState extends ConsumerState<ConversationScreen> {
  final _scrollController = ScrollController();
  bool _readMarked = false;

  /// Forces a hard jump-to-bottom on the very first emission so the
  /// user lands on the latest message. Subsequent emissions only
  /// auto-scroll if the user is already near the bottom (so reading
  /// older messages isn't yanked away by a fresh incoming).
  bool _initialScrollDone = false;
  int _lastMessageCount = 0;
  static const double _autoScrollThreshold = 80;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// Two-step destructive confirmation for "Supprimer la conversation".
  /// Both dialogs must be accepted before the hide-row is upserted.
  /// Each step has an explicit Annuler that aborts without touching
  /// the backend.
  Future<void> _confirmDeleteConversation({required bool isFr}) async {
    final user = ref.read(currentUserProvider);
    if (user == null) return;

    final firstOk = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          isFr
              ? 'Supprimer la conversation ?'
              : 'Delete this conversation?',
        ),
        content: Text(
          isFr
              ? 'Êtes-vous sûr(e) de vouloir supprimer cette conversation ?'
              : 'Are you sure you want to delete this conversation?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(isFr ? 'Annuler' : 'Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(isFr ? 'Continuer' : 'Continue'),
          ),
        ],
      ),
    );
    if (firstOk != true || !mounted) return;

    final secondOk = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isFr ? 'Confirmer la suppression' : 'Confirm deletion'),
        content: Text(
          isFr
              ? 'Cette action supprimera la conversation de votre messagerie. '
                  'Votre date pourra toujours voir l\'historique de son côté. '
                  'Confirmer ?'
              : 'This will remove the conversation from your inbox. Your '
                  "date will still see their copy. Confirm?",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(isFr ? 'Annuler' : 'Cancel'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: AppColors.error),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(isFr ? 'Supprimer' : 'Delete'),
          ),
        ],
      ),
    );
    if (secondOk != true || !mounted) return;

    try {
      await ref.read(messagingRepositoryProvider).hideConversation(
            conversationId: widget.conversationId,
            userId: user.id,
          );
    } catch (e, st) {
      const AppLogger('Conv').warn('hideConversation failed: $e\n$st');
      if (!mounted) return;
      context.showSnack(
        isFr ? 'Suppression impossible' : 'Could not delete',
      );
      return;
    }
    if (!mounted) return;
    Navigator.of(context).maybePop();
  }

  void _markReadOnce() {
    if (_readMarked) return;
    final user = ref.read(currentUserProvider);
    if (user == null) return;
    _readMarked = true;
    ref
        .read(messagingRepositoryProvider)
        .markAsRead(
          conversationId: widget.conversationId,
          readerId: user.id,
        )
        .then((_) {
      // `markAsRead` updates `messages.read_at` only — the inbox stream
      // watches `conversations`, so it won't re-emit on its own. We
      // invalidate BOTH:
      //   • inboxProvider → re-hydrates each tile's `unreadCount` (the
      //     per-conversation pink badge in the list),
      //   • unreadMessagesCountProvider → re-fetches the bottom-nav
      //     global counter (recomputed automatically once the inbox
      //     emits, but invalidate is more responsive).
      if (mounted) {
        ref.invalidate(inboxProvider);
        ref.invalidate(unreadMessagesCountProvider);
      }
    });
  }

  /// Hard jump (no animation) — used for the initial landing on the
  /// most recent message before the user has had a chance to scroll.
  void _jumpToBottom() {
    if (!_scrollController.hasClients) return;
    _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
  }

  /// Smooth scroll to the latest message.
  void _scrollToBottom() {
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      _scrollController.position.maxScrollExtent,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  /// True when the user is within [_autoScrollThreshold] px of the
  /// bottom — used to decide whether a fresh incoming should yank the
  /// view down or leave them reading older messages in peace.
  bool _isNearBottom() {
    if (!_scrollController.hasClients) return true;
    final pos = _scrollController.position;
    return (pos.maxScrollExtent - pos.pixels) <= _autoScrollThreshold;
  }

  /// Called on every messages emission to react appropriately:
  /// • first emission → hard jump to bottom (initial landing)
  /// • new incoming while user is near the bottom → smooth scroll
  /// • new incoming while user is reading older messages → no-op
  void _handleMessagesUpdated(int newCount) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_initialScrollDone) {
        _initialScrollDone = true;
        _jumpToBottom();
      } else if (newCount > _lastMessageCount && _isNearBottom()) {
        _scrollToBottom();
      }
      _lastMessageCount = newCount;
    });
  }

  Future<void> _send(String body) async {
    final user = ref.read(currentUserProvider);
    if (user == null) return;
    try {
      await ref.read(messagingRepositoryProvider).sendMessage(
            conversationId: widget.conversationId,
            senderId: user.id,
            body: body,
          );
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _scrollToBottom());
    } catch (e) {
      if (!mounted) return;
      context.showSnack('$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final messagesAsync =
        ref.watch(conversationMessagesProvider(widget.conversationId));
    final inboxAsync = ref.watch(inboxProvider);
    final Conversation? conversation = inboxAsync.maybeWhen(
      data: (list) {
        for (final c in list) {
          if (c.id == widget.conversationId) return c;
        }
        return null;
      },
      orElse: () => null,
    );

    // Whenever the messages stream emits:
    //  • mark all incoming peer messages as read (idempotent),
    //  • land the user on the latest message on first paint, then only
    //    auto-scroll on new arrivals if they're already near the bottom.
    messagesAsync.whenData((msgs) {
      _markReadOnce();
      _handleMessagesUpdated(msgs.length);
    });

    final isFr = Localizations.localeOf(context).languageCode == 'fr';
    final selfId = ref.watch(currentUserProvider)?.id;
    final peerId = conversation == null || selfId == null
        ? null
        : (conversation.userAId == selfId
            ? conversation.userBId
            : conversation.userAId);

    return AppScaffold(
      glowIntensity: 0.5,
      applyHorizontalPadding: false,
      appBar: AppBar(
        leading: const BackButton(),
        title: _PeerTitle(conversation: conversation, peerId: peerId),
        centerTitle: false,
        actions: [
          if (peerId != null)
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
              onSelected: (value) {
                if (value == 'report') {
                  showReportSheet(
                    context,
                    reportedUserId: peerId,
                    reportedDisplayName: conversation?.peerFirstName,
                  );
                } else if (value == 'delete') {
                  _confirmDeleteConversation(isFr: isFr);
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'report',
                  child: Row(
                    children: [
                      const Icon(Icons.flag_outlined, size: 18),
                      const SizedBox(width: AppSpacing.sm),
                      Text(isFr ? 'Signaler' : 'Report'),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'delete',
                  child: Row(
                    children: [
                      const Icon(Icons.delete_outline_rounded,
                          size: 18, color: AppColors.error),
                      const SizedBox(width: AppSpacing.sm),
                      Text(
                        isFr
                            ? 'Supprimer la conversation'
                            : 'Delete conversation',
                        style: const TextStyle(color: AppColors.error),
                      ),
                    ],
                  ),
                ),
              ],
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: messagesAsync.when(
              loading: () => const Center(child: LoadingIndicator()),
              // Never surface a raw PostgrestException to the user.
              // Treat as "no messages yet" — Realtime will populate the
              // list as soon as the stream re-establishes.
              error: (e, st) {
                const AppLogger('Conv').warn('messages error: $e\n$st');
                return _MessageList(
                  messages: const [],
                  scrollController: _scrollController,
                );
              },
              data: (msgs) => _MessageList(
                messages: msgs,
                scrollController: _scrollController,
              ),
            ),
          ),
          MessageInput(onSend: _send),
        ],
      ),
    );
  }
}

class _PeerTitle extends ConsumerWidget {
  const _PeerTitle({required this.conversation, this.peerId});

  final Conversation? conversation;

  /// Peer user id. When non-null, tapping the photo/name opens the
  /// read-only matched-profile card (access re-verified server-side).
  final String? peerId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final name = conversation?.peerFirstName ?? '—';
    final photoUrl = conversation?.peerPrimaryPhotoUrl;
    final id = peerId;
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (photoUrl != null)
          FutureBuilder(
            future: ref.read(profileRepositoryProvider).getPhotoBytes(photoUrl),
            builder: (context, snap) {
              if (snap.data == null) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(right: AppSpacing.sm),
                child: Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: AppColors.hairline),
                    image: DecorationImage(
                      image: MemoryImage(snap.data!),
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
              );
            },
          ),
        Flexible(
          child: Text(
            name,
            style: AppTypography.h3,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
    if (id == null) return row;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => context.pushNamed(
        AppRoute.matchedProfile.name,
        pathParameters: {'userId': id},
      ),
      child: row,
    );
  }
}

class _MessageList extends ConsumerWidget {
  const _MessageList({
    required this.messages,
    required this.scrollController,
  });

  final List<Message> messages;
  final ScrollController scrollController;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final user = ref.watch(currentUserProvider);
    final currentId = user?.id ?? '';
    if (messages.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Center(
          child: Text(
            l10n.conversationLockedSelf,
            textAlign: TextAlign.center,
            style: AppTypography.body.copyWith(color: AppColors.textTertiary),
          ),
        ),
      );
    }
    return ListView.builder(
      controller: scrollController,
      padding: const EdgeInsets.only(top: AppSpacing.sm, bottom: AppSpacing.sm),
      itemCount: messages.length,
      itemBuilder: (context, i) {
        final m = messages[i];
        // Only show the timestamp under the last message of a same-author
        // run — it keeps the chat tidy.
        final next = i + 1 < messages.length ? messages[i + 1] : null;
        final showTime = next == null || next.senderId != m.senderId;
        return MessageBubble(
          message: m,
          fromMe: m.isFromMe(currentId),
          showTime: showTime,
        );
      },
    );
  }
}
