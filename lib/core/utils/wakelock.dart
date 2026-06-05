import 'package:flutter/services.dart';

import 'logger.dart';

/// Keeps the screen awake during a live video date (FaceTime / Meet style),
/// via a native MethodChannel — no extra package.
///
/// iOS toggles `UIApplication.isIdleTimerDisabled`; Android toggles
/// `FLAG_KEEP_SCREEN_ON` (see SceneDelegate.swift / MainActivity.kt).
///
/// Always pair [enable] with [disable] — the call surface does this in
/// `initState` / `dispose` so the wakelock can never outlive the call. On web
/// or any platform without the handler the channel call simply no-ops.
class Wakelock {
  const Wakelock._();

  static const _channel = MethodChannel('datenow/wakelock');
  static const _log = AppLogger('Wakelock');

  /// Keep the screen on. Call when a live date starts.
  static Future<void> enable() => _set('enable');

  /// Restore normal auto-lock. Call when the date ends.
  static Future<void> disable() => _set('disable');

  static Future<void> _set(String method) async {
    try {
      await _channel.invokeMethod<void>(method);
      _log.info('wakelock $method');
    } catch (e) {
      // Non-fatal: a missing handler (web, tests, older build) must never
      // break the call flow.
      _log.warn('wakelock $method failed (ignored): $e');
    }
  }
}
