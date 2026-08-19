// Unread badge: pure formatting + the MessagingRepository mock contract.
//
// The server-side RPC (`unread_messages_count`) and RLS rules are tested
// at the SQL/structural level in supabase/tests/flow_checks.sql. What we
// pin down here in flutter_test:
//   1. The badge text rule never lies (0 hides, 1-9 literal, 10+ "9+").
//   2. The MessagingRepository mock — which mirrors the server contract
//      — never counts own messages, decrements after markAsRead, and
//      stays at 0 when there's nothing to read.

import 'package:datenow/app/scaffold/main_shell.dart';
import 'package:datenow/features/messaging/data/messaging_repository.dart';
import 'package:datenow/features/profile_setup/domain/enums.dart';
import 'package:datenow/features/profile_setup/domain/interest.dart';
import 'package:datenow/features/profile_setup/domain/user_profile.dart';
import 'package:flutter_test/flutter_test.dart';

UserProfile _peer({String userId = 'peer-B', String firstName = 'Peer'}) {
  return UserProfile(
    userId: userId,
    firstName: firstName,
    birthDate: DateTime(2000, 1, 1),
    gender: Gender.female,
    orientation: Orientation.straight,
    seekingGenders: const {Gender.male},
    seekingAgeMin: 22,
    seekingAgeMax: 40,
    maxDistanceKm: 50,
    intentions: const {Intention.feeling},
    interests: const <Interest>{Interest.music},
    availability: Availability.immediate,
  );
}

void main() {
  group('formatUnreadBadge', () {
    test('0 or negative → null (no badge rendered)', () {
      expect(formatUnreadBadge(0), isNull);
      expect(formatUnreadBadge(-1), isNull);
    });

    test('1 to 9 → literal digit', () {
      expect(formatUnreadBadge(1), '1');
      expect(formatUnreadBadge(4), '4');
      expect(formatUnreadBadge(9), '9');
    });

    test('10+ → clamped "9+"', () {
      expect(formatUnreadBadge(10), '9+');
      expect(formatUnreadBadge(42), '9+');
      expect(formatUnreadBadge(999), '9+');
    });
  });

  group('MockMessagingRepository.unreadMessagesCount', () {
    test('no conversations → 0', () async {
      final repo = MockMessagingRepository();
      expect(await repo.unreadMessagesCount('A'), 0);
    });

    test('peer sends 1 message → A has 1 unread', () async {
      final repo = MockMessagingRepository();
      final conv = await repo.ensureConversation(
        currentUserId: 'A',
        peer: _peer(),
      );
      await repo.sendMessage(
        conversationId: conv.id,
        senderId: 'peer-B',
        body: 'hi',
      );
      expect(await repo.unreadMessagesCount('A'), 1);
    });

    test('own messages never count toward our own unread', () async {
      final repo = MockMessagingRepository();
      final conv = await repo.ensureConversation(
        currentUserId: 'A',
        peer: _peer(),
      );
      // A sends 3 messages — A's unread must stay 0.
      for (var i = 0; i < 3; i++) {
        await repo.sendMessage(
          conversationId: conv.id,
          senderId: 'A',
          body: 'hello $i',
        );
      }
      expect(await repo.unreadMessagesCount('A'), 0);
      // Symmetric: peer's unread sees those 3.
      expect(await repo.unreadMessagesCount('peer-B'), 3);
    });

    test('markAsRead clears the badge for the reader only', () async {
      final repo = MockMessagingRepository();
      final conv = await repo.ensureConversation(
        currentUserId: 'A',
        peer: _peer(),
      );
      await repo.sendMessage(
        conversationId: conv.id,
        senderId: 'peer-B',
        body: 'hi',
      );
      await repo.sendMessage(
        conversationId: conv.id,
        senderId: 'peer-B',
        body: 'still here?',
      );
      expect(await repo.unreadMessagesCount('A'), 2);

      await repo.markAsRead(conversationId: conv.id, readerId: 'A');
      expect(await repo.unreadMessagesCount('A'), 0);
      // The peer's own messages don't count for the peer either.
      expect(await repo.unreadMessagesCount('peer-B'), 0);
    });

    test('mixed senders: each side sees only the OTHER side as unread',
        () async {
      final repo = MockMessagingRepository();
      final conv = await repo.ensureConversation(
        currentUserId: 'A',
        peer: _peer(),
      );
      await repo.sendMessage(
        conversationId: conv.id,
        senderId: 'A',
        body: 'ping',
      );
      await repo.sendMessage(
        conversationId: conv.id,
        senderId: 'peer-B',
        body: 'pong',
      );
      await repo.sendMessage(
        conversationId: conv.id,
        senderId: 'peer-B',
        body: 'still here',
      );
      expect(await repo.unreadMessagesCount('A'), 2); // 2 from peer
      expect(await repo.unreadMessagesCount('peer-B'), 1); // 1 from A
    });
  });

  group('Inbox per-conversation unreadCount clears on markAsRead', () {
    test(
        'opening a chat → that conversation tile shows unreadCount = 0 on the next inbox snapshot',
        () async {
      final repo = MockMessagingRepository();
      final conv = await repo.ensureConversation(
        currentUserId: 'A',
        peer: _peer(),
      );
      await repo.sendMessage(
        conversationId: conv.id,
        senderId: 'peer-B',
        body: 'hello A',
      );
      await repo.sendMessage(
        conversationId: conv.id,
        senderId: 'peer-B',
        body: 'still here',
      );

      // Fresh stream each time — the mock's async* generator is
      // single-subscription, so re-listening to the same instance
      // would throw.
      final before = await repo.watchInbox('A').first;
      expect(before.single.unreadCount, 2,
          reason: 'A should see 2 unread in the inbox tile before opening');

      await repo.markAsRead(conversationId: conv.id, readerId: 'A');

      final after = await repo.watchInbox('A').first;
      expect(after.single.unreadCount, 0,
          reason: 'Tile badge must clear immediately on read');
      // And A's global count is back to 0.
      expect(await repo.unreadMessagesCount('A'), 0);
    });
  });

  group('MockMessagingRepository.hideConversation', () {
    test(
        'hideConversation removes the conversation from the deleting user\'s inbox '
        'but keeps it on the peer side', () async {
      final repo = MockMessagingRepository();
      final conv = await repo.ensureConversation(
        currentUserId: 'A',
        peer: _peer(userId: 'B'),
      );
      // Sanity: both sides see it.
      expect((await repo.watchInbox('A').first).map((c) => c.id),
          contains(conv.id));
      expect((await repo.watchInbox('B').first).map((c) => c.id),
          contains(conv.id));

      await repo.hideConversation(conversationId: conv.id, userId: 'A');

      expect(
        (await repo.watchInbox('A').first).map((c) => c.id),
        isNot(contains(conv.id)),
        reason: 'A hid the conversation — must not appear in their inbox',
      );
      expect(
        (await repo.watchInbox('B').first).map((c) => c.id),
        contains(conv.id),
        reason: "B did not hide — must still see the conversation",
      );
    });

    test(
        'a new message after hide resurrects the conversation in the inbox',
        () async {
      final repo = MockMessagingRepository();
      final conv = await repo.ensureConversation(
        currentUserId: 'A',
        peer: _peer(userId: 'B'),
      );
      await repo.hideConversation(conversationId: conv.id, userId: 'A');
      expect((await repo.watchInbox('A').first).map((c) => c.id),
          isNot(contains(conv.id)));
      // Mock sendMessage updates last_message_at to now() — strictly
      // after the hide timestamp, so the inbox filter resurrects it.
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await repo.sendMessage(
        conversationId: conv.id,
        senderId: 'B',
        body: 'Tu m\'as oublié·e ?',
      );
      expect(
        (await repo.watchInbox('A').first).map((c) => c.id),
        contains(conv.id),
        reason: 'New message must un-hide for A (product rule)',
      );
    });
  });

  group('Message order — oldest top, newest bottom', () {
    test(
        'watchMessages emits the messages in insertion order (chat-app standard)',
        () async {
      final repo = MockMessagingRepository();
      final conv = await repo.ensureConversation(
        currentUserId: 'A',
        peer: _peer(),
      );
      // Send 3 messages in time order — we expect the same order back.
      for (final body in ['first', 'second', 'third']) {
        await repo.sendMessage(
          conversationId: conv.id,
          senderId: 'A',
          body: body,
        );
      }
      final msgs = await repo.watchMessages(conv.id).first;
      expect(
        msgs.map((m) => m.body).toList(),
        ['first', 'second', 'third'],
        reason:
            'Order must be ASCENDING (oldest first) so a non-reversed '
            'ListView renders the latest at the bottom.',
      );
    });
  });

  unmatchTests();
}

// ---------------------------------------------------------------------------
// unmatch — the softer exit added by UX plan point 8
// ---------------------------------------------------------------------------
//
// Ending a match used to mean escalating to a block, or soft-deleting your
// own copy of the thread while the match itself quietly stayed alive. These
// exercise the mock, which mirrors what the SECURITY DEFINER RPC does
// server-side: the pair and the thread go for BOTH sides.

void unmatchTests() {
  group('MockMessagingRepository.unmatch', () {
    test('removes the conversation from both inboxes, not just the caller\'s',
        () async {
      final repo = MockMessagingRepository();
      final conv = await repo.ensureConversation(
        currentUserId: 'A',
        peer: _peer(),
      );
      await repo.sendMessage(
        conversationId: conv.id,
        senderId: 'A',
        body: 'hello',
      );

      await repo.unmatch(peerId: 'peer-B');

      expect(await repo.watchInbox('A').first, isEmpty);
      expect(await repo.watchInbox('peer-B').first, isEmpty);
    });

    test('is idempotent — a retry after a dropped connection is harmless',
        () async {
      final repo = MockMessagingRepository();
      await repo.ensureConversation(currentUserId: 'A', peer: _peer());
      await repo.unmatch(peerId: 'peer-B');
      await repo.unmatch(peerId: 'peer-B');
      expect(await repo.watchInbox('A').first, isEmpty);
    });

    test('leaves conversations with other people alone', () async {
      final repo = MockMessagingRepository();
      await repo.ensureConversation(currentUserId: 'A', peer: _peer());
      await repo.ensureConversation(
        currentUserId: 'A',
        peer: _peer(userId: 'peer-C', firstName: 'Other'),
      );

      await repo.unmatch(peerId: 'peer-B');

      final inbox = await repo.watchInbox('A').first;
      expect(inbox, hasLength(1));
      expect(
        inbox.single.userAId == 'peer-C' || inbox.single.userBId == 'peer-C',
        isTrue,
      );
    });
  });
}
