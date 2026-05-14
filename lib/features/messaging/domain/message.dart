import 'package:freezed_annotation/freezed_annotation.dart';

part 'message.freezed.dart';

/// One row of `public.messages`.
///
/// [readAt] is `null` until the recipient opens the conversation. The
/// inbox uses it to compute the unread badge; the chat screen flips it to
/// `now()` for every incoming message when the screen mounts.
@freezed
class Message with _$Message {
  const Message._();

  const factory Message({
    required String id,
    required String conversationId,
    required String senderId,
    required String body,
    required DateTime createdAt,
    DateTime? readAt,
  }) = _Message;

  bool isFromMe(String currentUserId) => senderId == currentUserId;
  bool get isUnread => readAt == null;
}
