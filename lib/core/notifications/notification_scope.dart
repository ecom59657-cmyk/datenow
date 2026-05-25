import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/auth/presentation/providers/auth_provider.dart';
import '../../features/messaging/domain/conversation.dart';
import '../../features/messaging/presentation/providers/messaging_providers.dart';
import 'notification_service.dart';

/// Listens to [inboxProvider] and fires
/// [NotificationService.instance.handleNewMessage] when a fresh incoming
/// message (from someone other than the caller) lands.
///
/// Mounted inside [MainShell] so it only runs for authenticated users
/// (no point watching the inbox stream when signed out) and the
/// snackbar surfaces over the bottom nav via [rootScaffoldMessengerKey].
///
/// Initial-mount messages do NOT trigger feedback — we only react to
/// conversations whose `lastMessageAt` is newer than the timestamp the
/// scope was mounted at. Otherwise reopening the app would beep for
/// every old unread.
class NotificationScope extends ConsumerStatefulWidget {
  const NotificationScope({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<NotificationScope> createState() => _NotificationScopeState();
}

class _NotificationScopeState extends ConsumerState<NotificationScope> {
  /// Highest `lastMessageAt` we've already produced feedback for.
  /// Seeded with mount time so existing unreads at app launch never
  /// trigger a burst of beeps.
  DateTime _highWaterMark = DateTime.now().toUtc();

  @override
  Widget build(BuildContext context) {
    final selfId = ref.watch(currentUserProvider)?.id;
    ref.listen<AsyncValue<List<Conversation>>>(inboxProvider, (prev, next) {
      next.whenData((list) => _consume(list, selfId));
    });
    return widget.child;
  }

  void _consume(List<Conversation> conversations, String? selfId) {
    if (selfId == null) return;
    DateTime? newest;
    Conversation? newestConv;
    for (final c in conversations) {
      final t = c.lastMessageAt;
      if (t == null) continue;
      // `unreadCount > 0` filters out messages we sent ourselves —
      // our own messages don't bump our unread count (see the
      // SECURITY DEFINER RPC), so this is a precise "fresh incoming"
      // signal.
      if (c.unreadCount <= 0) continue;
      if (!t.isAfter(_highWaterMark)) continue;
      if (newest == null || t.isAfter(newest)) {
        newest = t;
        newestConv = c;
      }
    }
    if (newest == null || newestConv == null) return;
    _highWaterMark = newest;
    NotificationService.instance.handleNewMessage(
      conversationId: newestConv.id,
      senderFirstName: newestConv.peerFirstName ?? '',
      preview: newestConv.lastMessagePreview ?? '',
    );
  }
}
