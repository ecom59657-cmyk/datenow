import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _markReadOnce() {
    if (_readMarked) return;
    final user = ref.read(currentUserProvider);
    if (user == null) return;
    _readMarked = true;
    ref.read(messagingRepositoryProvider).markAsRead(
          conversationId: widget.conversationId,
          readerId: user.id,
        );
  }

  void _scrollToBottom() {
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      _scrollController.position.maxScrollExtent,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
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

    // First successful render = mark all peer messages as read.
    messagesAsync.whenData((_) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _markReadOnce();
          _scrollToBottom();
        }
      });
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
        title: _PeerTitle(conversation: conversation),
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
  const _PeerTitle({required this.conversation});

  final Conversation? conversation;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final name = conversation?.peerFirstName ?? '—';
    final photoUrl = conversation?.peerPrimaryPhotoUrl;
    return Row(
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
