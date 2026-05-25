// =============================================================================
// DateNow — notification service (in-app feedback OFF, push scaffolded)
//
// Product decision: stop showing snackbars / playing sounds inside the
// app on every new message. New messages will land as real iOS push
// notifications instead — see `docs/PUSH_NOTIFICATIONS_SETUP.md` for
// the Apple-side steps (APNs key, Xcode capability, Supabase secrets)
// that activate delivery once flipped on.
//
// While the integration is in place but not yet live, this service is
// a deliberate NO-OP so the existing call sites (NotificationScope)
// keep compiling and we don't need to ship a churn-y removal.
//
// What stays in place regardless of push:
//   • Unread badge on the Messages bottom-nav tab
//     (`unreadMessagesCountProvider`).
//   • Per-conversation unread tile badge (Conversation.unreadCount).
//   • Realtime message stream + mark-as-read on open.
//
// What used to live here and is intentionally removed:
//   • SystemSound.alert
//   • HapticFeedback.lightImpact
//   • ScaffoldMessenger snackbar showing the message body / sender.
// =============================================================================

import 'package:flutter/material.dart';

import '../utils/logger.dart';

/// Kept for future use (in-app banners on receipt confirmations etc.),
/// but the message-arrival path no longer pushes a snackbar through it.
final GlobalKey<ScaffoldMessengerState> rootScaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

class NotificationService {
  NotificationService._();

  static final NotificationService instance = NotificationService._();

  static const _log = AppLogger('Notifications');

  /// Called by [NotificationScope] when a fresh peer message arrives.
  /// Today: log only. Real-time iOS push delivery is owned by the
  /// `message-notification` Edge Function — see PUSH_NOTIFICATIONS_SETUP.md.
  void handleNewMessage({
    required String conversationId,
    required String senderFirstName,
    required String preview,
  }) {
    _log.info(
      'newMessage observed (in-app feedback disabled) — '
      'conv=$conversationId from=$senderFirstName',
    );
  }
}
