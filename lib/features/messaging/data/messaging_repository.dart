import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

import '../../../core/services/supabase_service.dart';
import '../../../core/utils/logger.dart';
import '../../profile_setup/domain/user_profile.dart';
import '../domain/conversation.dart';
import '../domain/message.dart';

/// Single surface the rest of the app talks to for messaging. Both backends
/// (Supabase + in-memory mock) implement the same shape so screens stay
/// backend-agnostic.
///
/// **Product invariant**: a conversation row is **only ever inserted** by
/// the post-call screen when both peers chose to match. There is no UI
/// path that creates a conversation from anywhere else in the app, and
/// the Supabase RLS guarantees the inserter must be one of the two
/// participants.
abstract class MessagingRepository {
  /// Streams the current user's inbox — ordered most-recent-first.
  Stream<List<Conversation>> watchInbox(String userId);

  /// Streams the messages of [conversationId] in chronological order.
  Stream<List<Message>> watchMessages(String conversationId);

  /// Inserts a message authored by [senderId]. Returns the freshly-created
  /// row so the UI can optimistically render before realtime catches up.
  Future<Message> sendMessage({
    required String conversationId,
    required String senderId,
    required String body,
  });

  /// Idempotent — returns the existing conversation between the two users
  /// or creates one. Called from the post-call screen at the moment the
  /// mutual match is confirmed.
  Future<Conversation> ensureConversation({
    required String currentUserId,
    required UserProfile peer,
  });

  /// One-shot lookup by id, used when the user taps a [MatchCard] and we
  /// need to navigate to a specific chat.
  Future<Conversation?> findConversationWithPeer({
    required String currentUserId,
    required String peerId,
  });

  /// Marks every message in [conversationId] not authored by [readerId] as
  /// read. Called when the chat screen mounts so the unread badge clears.
  Future<void> markAsRead({
    required String conversationId,
    required String readerId,
  });
}

// ---------------------------------------------------------------------------
// Mock — in-memory, broadcast streams, instant
// ---------------------------------------------------------------------------

/// Demo-mode messaging. Keeps everything in memory and exposes broadcast
/// streams so the inbox + chat screens react instantly. Resets on browser
/// reload — fine for the MVP.
class MockMessagingRepository implements MessagingRepository {
  MockMessagingRepository();

  static const _log = AppLogger('MockMessaging');

  // Conversation storage, keyed by conversation id.
  final Map<String, Conversation> _conversations = {};
  final Map<String, List<Message>> _messages = {};

  // One stream per user (their inbox) and per conversation (the chat).
  final Map<String, StreamController<List<Conversation>>> _inboxStreams = {};
  final Map<String, StreamController<List<Message>>> _messageStreams = {};

  int _seq = 0;

  StreamController<List<Conversation>> _inboxStream(String userId) =>
      _inboxStreams.putIfAbsent(
        userId,
        () => StreamController<List<Conversation>>.broadcast(),
      );

  StreamController<List<Message>> _messageStream(String conversationId) =>
      _messageStreams.putIfAbsent(
        conversationId,
        () => StreamController<List<Message>>.broadcast(),
      );

  List<Conversation> _inboxFor(String userId) {
    final mine = _conversations.values
        .where((c) => c.userAId == userId || c.userBId == userId)
        .map((c) => c.copyWith(
              unreadCount: (_messages[c.id] ?? const <Message>[])
                  .where((m) => m.senderId != userId && m.readAt == null)
                  .length,
            ))
        .toList();
    mine.sort((a, b) {
      final ta = a.lastMessageAt ?? a.createdAt;
      final tb = b.lastMessageAt ?? b.createdAt;
      return tb.compareTo(ta);
    });
    return mine;
  }

  void _emitInbox(String userId) {
    _inboxStream(userId).add(_inboxFor(userId));
  }

  void _emitMessages(String conversationId) {
    _messageStream(conversationId)
        .add(List.unmodifiable(_messages[conversationId] ?? const []));
  }

  @override
  Stream<List<Conversation>> watchInbox(String userId) async* {
    yield _inboxFor(userId);
    yield* _inboxStream(userId).stream;
  }

  @override
  Stream<List<Message>> watchMessages(String conversationId) async* {
    yield List.unmodifiable(_messages[conversationId] ?? const []);
    yield* _messageStream(conversationId).stream;
  }

  @override
  Future<Message> sendMessage({
    required String conversationId,
    required String senderId,
    required String body,
  }) async {
    final now = DateTime.now();
    final msg = Message(
      id: 'mock-msg-${now.microsecondsSinceEpoch}-${_seq++}',
      conversationId: conversationId,
      senderId: senderId,
      body: body,
      createdAt: now,
    );
    _messages.putIfAbsent(conversationId, () => <Message>[]).add(msg);

    // Update last_message_at / preview.
    final conv = _conversations[conversationId];
    if (conv != null) {
      _conversations[conversationId] = conv.copyWith(
        lastMessageAt: now,
        lastMessagePreview: body.length > 140 ? body.substring(0, 140) : body,
      );
      _emitInbox(conv.userAId);
      _emitInbox(conv.userBId);
    }
    _emitMessages(conversationId);
    return msg;
  }

  @override
  Future<Conversation> ensureConversation({
    required String currentUserId,
    required UserProfile peer,
  }) async {
    final existing = _conversations.values.firstWhereOrNull(
      (c) =>
          (c.userAId == currentUserId && c.userBId == peer.userId) ||
          (c.userAId == peer.userId && c.userBId == currentUserId),
    );
    if (existing != null) return existing;

    final ids = [currentUserId, peer.userId]..sort();
    final conv = Conversation(
      id: 'mock-conv-${DateTime.now().microsecondsSinceEpoch}',
      userAId: ids.first,
      userBId: ids.last,
      createdAt: DateTime.now(),
      peerFirstName: peer.firstName,
      peerPrimaryPhotoUrl: peer.primaryPhotoUrl,
    );
    _conversations[conv.id] = conv;
    _emitInbox(currentUserId);
    _emitInbox(peer.userId);
    _log.info('mock conversation created: ${conv.id}');
    return conv;
  }

  @override
  Future<Conversation?> findConversationWithPeer({
    required String currentUserId,
    required String peerId,
  }) async {
    return _conversations.values.firstWhereOrNull(
      (c) =>
          (c.userAId == currentUserId && c.userBId == peerId) ||
          (c.userAId == peerId && c.userBId == currentUserId),
    );
  }

  @override
  Future<void> markAsRead({
    required String conversationId,
    required String readerId,
  }) async {
    final list = _messages[conversationId];
    if (list == null) return;
    final now = DateTime.now();
    final next = list.map((m) {
      if (m.senderId == readerId || m.readAt != null) return m;
      return m.copyWith(readAt: now);
    }).toList();
    _messages[conversationId] = next;
    _emitMessages(conversationId);
    // Inbox unread counts depend on read_at — re-emit.
    final conv = _conversations[conversationId];
    if (conv != null) {
      _emitInbox(conv.userAId);
      _emitInbox(conv.userBId);
    }
  }
}

extension on Iterable<Conversation> {
  Conversation? firstWhereOrNull(bool Function(Conversation) test) {
    for (final c in this) {
      if (test(c)) return c;
    }
    return null;
  }
}

// ---------------------------------------------------------------------------
// Supabase — realtime + REST
// ---------------------------------------------------------------------------

class SupabaseMessagingRepository implements MessagingRepository {
  SupabaseMessagingRepository(this._client);

  final sb.SupabaseClient _client;
  static const _log = AppLogger('SupabaseMessaging');

  @override
  Stream<List<Conversation>> watchInbox(String userId) {
    // Supabase's `.stream()` filters server-side. We use a two-OR filter
    // by streaming everything and filtering client-side — simpler than
    // running two parallel subscriptions.
    return _client
        .from('conversations')
        .stream(primaryKey: ['id'])
        .order('last_message_at')
        .asyncMap((rows) async {
      final mine = rows.where((r) {
        return r['user_a_id'] == userId || r['user_b_id'] == userId;
      }).toList();

      final convs = <Conversation>[];
      for (final row in mine) {
        final conv = await _hydrateConversation(row, currentUserId: userId);
        convs.add(conv);
      }
      convs.sort((a, b) {
        final ta = a.lastMessageAt ?? a.createdAt;
        final tb = b.lastMessageAt ?? b.createdAt;
        return tb.compareTo(ta);
      });
      return convs;
    });
  }

  Future<Conversation> _hydrateConversation(
    Map<String, dynamic> row, {
    required String currentUserId,
  }) async {
    final id = row['id'] as String;
    final userA = row['user_a_id'] as String;
    final userB = row['user_b_id'] as String;
    final peerId = currentUserId == userA ? userB : userA;

    // Peer first name + primary photo. Best-effort; if the row isn't
    // readable (RLS), we surface what we have.
    String? peerName;
    String? peerPhoto;
    try {
      final peerRow = await _client
          .from('profiles')
          .select('first_name')
          .eq('id', peerId)
          .maybeSingle();
      peerName = peerRow?['first_name'] as String?;
    } catch (_) {/* ignore */}
    try {
      final photoRow = await _client
          .from('user_photos')
          .select('storage_path')
          .eq('user_id', peerId)
          .order('position')
          .limit(1)
          .maybeSingle();
      peerPhoto = photoRow?['storage_path'] as String?;
    } catch (_) {/* ignore */}

    // Unread count = messages from peer with read_at IS NULL.
    int unread = 0;
    try {
      final unreadRows = await _client
          .from('messages')
          .select('id')
          .eq('conversation_id', id)
          .eq('sender_id', peerId)
          .isFilter('read_at', null);
      unread = (unreadRows as List).length;
    } catch (_) {/* ignore */}

    return Conversation(
      id: id,
      userAId: userA,
      userBId: userB,
      lastMessageAt: _parseDate(row['last_message_at']),
      lastMessagePreview: row['last_message_preview'] as String?,
      unreadCount: unread,
      createdAt: _parseDate(row['created_at']) ?? DateTime.now(),
      peerFirstName: peerName,
      peerPrimaryPhotoUrl: peerPhoto,
    );
  }

  @override
  Stream<List<Message>> watchMessages(String conversationId) {
    return _client
        .from('messages')
        .stream(primaryKey: ['id'])
        .eq('conversation_id', conversationId)
        .order('created_at')
        .map(
          (rows) => rows.map(_mapMessage).toList(growable: false),
        );
  }

  Message _mapMessage(Map<String, dynamic> row) {
    return Message(
      id: row['id'] as String,
      conversationId: row['conversation_id'] as String,
      senderId: row['sender_id'] as String,
      body: row['body'] as String,
      createdAt: _parseDate(row['created_at']) ?? DateTime.now(),
      readAt: _parseDate(row['read_at']),
    );
  }

  DateTime? _parseDate(Object? raw) {
    if (raw == null) return null;
    if (raw is DateTime) return raw;
    return DateTime.tryParse(raw.toString());
  }

  @override
  Future<Message> sendMessage({
    required String conversationId,
    required String senderId,
    required String body,
  }) async {
    final trimmed = body.trim();
    _log.info('sendMessage → $conversationId (${trimmed.length} chars)');
    final inserted = await _client
        .from('messages')
        .insert({
          'conversation_id': conversationId,
          'sender_id': senderId,
          'body': trimmed,
        })
        .select()
        .single();
    return _mapMessage(inserted);
  }

  @override
  Future<Conversation> ensureConversation({
    required String currentUserId,
    required UserProfile peer,
  }) async {
    final existing = await findConversationWithPeer(
      currentUserId: currentUserId,
      peerId: peer.userId,
    );
    if (existing != null) return existing;

    final ids = [currentUserId, peer.userId]..sort();
    _log.info('ensureConversation: creating ${ids.first} ↔ ${ids.last}');
    final inserted = await _client
        .from('conversations')
        .insert({
          'user_a_id': ids.first,
          'user_b_id': ids.last,
        })
        .select()
        .single();
    return _hydrateConversation(inserted, currentUserId: currentUserId);
  }

  @override
  Future<Conversation?> findConversationWithPeer({
    required String currentUserId,
    required String peerId,
  }) async {
    final ids = [currentUserId, peerId]..sort();
    final row = await _client
        .from('conversations')
        .select()
        .eq('user_a_id', ids.first)
        .eq('user_b_id', ids.last)
        .maybeSingle();
    if (row == null) return null;
    return _hydrateConversation(row, currentUserId: currentUserId);
  }

  @override
  Future<void> markAsRead({
    required String conversationId,
    required String readerId,
  }) async {
    await _client
        .from('messages')
        .update({'read_at': DateTime.now().toIso8601String()})
        .eq('conversation_id', conversationId)
        .neq('sender_id', readerId)
        .isFilter('read_at', null);
  }
}

// ---------------------------------------------------------------------------
// Provider
// ---------------------------------------------------------------------------

final messagingRepositoryProvider = Provider<MessagingRepository>((ref) {
  final available = ref.watch(supabaseAvailableProvider);
  if (available) {
    return SupabaseMessagingRepository(ref.watch(supabaseClientProvider));
  }
  return MockMessagingRepository();
});
