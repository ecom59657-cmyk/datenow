import 'package:freezed_annotation/freezed_annotation.dart';

part 'conversation.freezed.dart';

/// One row of `public.conversations`. The pair is canonical
/// (`user_a_id < user_b_id`) — UI uses [peerIdFor] to resolve who's
/// "the other person" from the current user's point of view.
@freezed
class Conversation with _$Conversation {
  const Conversation._();

  const factory Conversation({
    required String id,
    required String userAId,
    required String userBId,
    String? lastMessagePreview,
    DateTime? lastMessageAt,
    @Default(0) int unreadCount,
    required DateTime createdAt,
    // Snapshot of the peer's display info — populated by the repo so the
    // inbox UI doesn't have to do a second round-trip per row.
    String? peerFirstName,
    String? peerPrimaryPhotoUrl,
  }) = _Conversation;

  /// Returns the user id of "the other person" given the current user.
  String peerIdFor(String currentUserId) =>
      currentUserId == userAId ? userBId : userAId;
}
