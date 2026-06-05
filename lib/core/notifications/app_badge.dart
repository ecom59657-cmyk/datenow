import 'package:flutter/services.dart';

import '../utils/logger.dart';

/// iOS app-icon badge + delivered-notification cleanup, via a native
/// MethodChannel (no extra package — see SceneDelegate.swift).
///
/// The badge always reflects the REAL total of unread incoming messages:
/// Dart sets it from `unread_messages_count()` on read / resume, and the
/// `message-notification` Edge Function sets it on each push.
class AppBadge {
  const AppBadge._();

  static const _channel = MethodChannel('datenow/badge');
  static const _log = AppLogger('Badge');

  /// Set the app-icon badge to [count] (clamped to >= 0 natively).
  static Future<void> setCount(int count) async {
    try {
      await _channel.invokeMethod<void>('setBadge', count);
    } catch (e) {
      _log.warn('setBadge($count) failed (ignored): $e');
    }
  }

  /// Remove the delivered iOS notifications that belong to [conversationId]
  /// (matched on the push payload's `conversation_id`). Called when the user
  /// reads that conversation so stale banners don't linger.
  static Future<void> clearConversation(String conversationId) async {
    try {
      await _channel.invokeMethod<void>('clearConversation', conversationId);
    } catch (e) {
      _log.warn('clearConversation failed (ignored): $e');
    }
  }
}
