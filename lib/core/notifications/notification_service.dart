// =============================================================================
// DateNow — in-app notification feedback
//
// MVP scope: while the app is in the foreground, a fresh incoming
// message produces a discreet sound + haptic + snackbar. The
// `NotificationScope` widget detects new messages by watching
// `inboxProvider`; this service is the per-event sink (sound, haptic,
// throttle, and an optional in-app snackbar via the global messenger).
//
// True OS push notifications (APNs) require an Apple/Firebase setup
// that's still out of scope for this iteration — TestFlight must keep
// working without them. The TODO at the bottom documents the path.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../utils/logger.dart';

/// Lives at the root of the widget tree; `ScaffoldMessenger.maybeOf`
/// uses it to surface a snackbar from anywhere without needing a
/// route's BuildContext.
final GlobalKey<ScaffoldMessengerState> rootScaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

class NotificationService {
  NotificationService._();

  static final NotificationService instance = NotificationService._();

  static const _log = AppLogger('Notifications');

  /// Throttle window — multiple incoming messages in quick succession
  /// only trigger one feedback. Prevents a burst of beeps when a peer
  /// types fast.
  static const _throttle = Duration(seconds: 2);
  DateTime? _lastPlayed;

  /// Called by [NotificationScope] when a fresh peer message arrives
  /// (sender_id <> self, lastMessageAt > previous mark). Plays a
  /// discreet system sound + a light haptic + a snackbar with
  /// "Nouveau message de {sender}". Throttled to one event every 2 s.
  void handleNewMessage({
    required String conversationId,
    required String senderFirstName,
    required String preview,
    bool playSound = true,
  }) {
    final now = DateTime.now();
    if (_lastPlayed != null && now.difference(_lastPlayed!) < _throttle) {
      _log.info('newMessage throttled (within ${_throttle.inSeconds}s)');
      return;
    }
    _lastPlayed = now;

    _log.info(
      'newMessage — conv=$conversationId from=$senderFirstName: '
      '${preview.length > 40 ? '${preview.substring(0, 40)}…' : preview}',
    );

    if (playSound) {
      // SystemSound.alert is the iOS-native discreet beep — no asset
      // bundling, no audio_session config, no permission prompt.
      // Falls back to a no-op on web silently.
      // ignore: discarded_futures
      SystemSound.play(SystemSoundType.alert);
    }
    // Tactile cue — meaningful but not aggressive on iPhone's Taptic.
    HapticFeedback.lightImpact();

    _showSnackbar(senderFirstName, preview);
  }

  void _showSnackbar(String senderFirstName, String preview) {
    final messenger = rootScaffoldMessengerKey.currentState;
    if (messenger == null) return; // no messenger mounted yet
    final shortPreview =
        preview.length > 80 ? '${preview.substring(0, 80)}…' : preview;
    final title = senderFirstName.trim().isEmpty
        ? 'Nouveau message'
        : 'Nouveau message de $senderFirstName';
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 3),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 88),
          content: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (shortPreview.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  shortPreview,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
              ],
            ],
          ),
        ),
      );
  }
}

// =============================================================================
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
// =============================================================================
