// =============================================================================
// DateNow — notification service abstraction (stub)
//
// MVP scope: the bottom-nav Messages badge surfaces new messages while
// the app is open (see `unreadMessagesCountProvider`). True OS push
// notifications (APNs / FCM) require an Apple/Firebase setup that's out
// of scope for this iteration — TestFlight build must keep working
// without them.
//
// This file documents the architecture so adding APNs later is a fill-in
// rather than a re-design.
//
// TODO(notifications):
//   1. Create an Edge Function (`message-notification`) triggered by an
//      INSERT on `public.messages` (via a Postgres webhook).
//   2. That function reads the recipient's APNs token from a new
//      `device_tokens` table, calls Apple's HTTP/2 endpoint, and sends a
//      payload like:
//        { aps: { alert: { title: "Nouveau message",
//                          body: "{senderFirstName}: {preview}" },
//                 sound: "default", badge: <unread count> },
//          dn_conversation_id: "<uuid>" }
//   3. Flutter side: integrate `firebase_messaging` (FCM-via-APNs) or
//      `flutter_apns`, store the token in `device_tokens` on launch,
//      handle the tap to deep-link to `/messages/:id`.
//   4. Surface an in-app toast for foreground deliveries via
//      `ScaffoldMessenger` from a global `notificationKey`.
//
// For now this file just exists so the import path is stable and the
// abstraction is in place — `NotificationService.instance.handleNewMessage`
// is a no-op that the future implementation will fill in.
// =============================================================================

import '../utils/logger.dart';

class NotificationService {
  NotificationService._();

  static final NotificationService instance = NotificationService._();

  static const _log = AppLogger('Notifications');

  /// Called when a fresh incoming message is detected (e.g. from the
  /// inbox realtime stream). Today: logs only. Tomorrow: surfaces a
  /// foreground toast and / or schedules a local notification.
  void handleNewMessage({
    required String conversationId,
    required String senderFirstName,
    required String preview,
  }) {
    // TODO(notifications): show in-app toast via a global ScaffoldMessenger.
    _log.info(
      'newMessage stub — conv=$conversationId from=$senderFirstName: '
      '${preview.length > 40 ? '${preview.substring(0, 40)}…' : preview}',
    );
  }
}
