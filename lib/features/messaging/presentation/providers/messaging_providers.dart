import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../auth/presentation/providers/auth_provider.dart';
import '../../../profile_setup/presentation/providers/profile_provider.dart';
import '../../data/messaging_repository.dart';
import '../../domain/conversation.dart';
import '../../domain/message.dart';

/// Inbox = the current user's conversation list, most-recent-first.
final inboxProvider = StreamProvider<List<Conversation>>((ref) {
  final user = ref.watch(currentUserProvider);
  if (user == null) {
    return Stream<List<Conversation>>.value(const <Conversation>[]);
  }
  return ref.watch(messagingRepositoryProvider).watchInbox(user.id);
});

/// Live message stream for [conversationId]. Family-scoped so multiple
/// chats can be opened in different routes without crossing wires.
final conversationMessagesProvider =
    StreamProvider.autoDispose.family<List<Message>, String>(
  (ref, conversationId) {
    return ref
        .watch(messagingRepositoryProvider)
        .watchMessages(conversationId);
  },
);

/// One-shot lookup used when the user taps a [MatchCard]: returns the
/// existing conversation (it must already exist — the post-call screen
/// creates it the moment both peers match).
final conversationByPeerProvider =
    FutureProvider.autoDispose.family<Conversation?, String>(
  (ref, peerId) async {
    final user = ref.watch(currentUserProvider);
    final profile = ref.watch(currentProfileProvider).asData?.value;
    final currentId = user?.id ?? profile?.userId;
    if (currentId == null) return null;
    return ref
        .read(messagingRepositoryProvider)
        .findConversationWithPeer(
          currentUserId: currentId,
          peerId: peerId,
        );
  },
);
