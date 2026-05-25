// =============================================================================
// DateNow — iOS push notifications (APNs via Firebase Messaging bridge)
//
// Firebase Messaging is used ONLY as the iOS APNs bridge — to request
// the system permission, retrieve the APNs device token, and surface
// foreground / background / cold-start notification taps. We do NOT
// use FCM topics or any other Firebase service. The push payload is
// signed and delivered by our `message-notification` Supabase Edge
// Function over APNs HTTP/2.
//
// Init is wrapped in try/catch so a missing `GoogleService-Info.plist`
// (e.g. on a teammate's machine that hasn't set up Firebase yet) does
// not crash the app — push features become a silent no-op until the
// plist is in place. See docs/PUSH_NOTIFICATIONS_SETUP.md.
// =============================================================================

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../app/router/app_router.dart';
import '../../app/router/app_routes.dart';
import '../utils/logger.dart';

class PushNotificationsService {
  PushNotificationsService._();

  static final PushNotificationsService instance =
      PushNotificationsService._();

  static const _log = AppLogger('Push');

  bool _initialized = false;
  bool _firebaseReady = false;
  FirebaseMessaging? _fm;

  /// True once Firebase is up and the iOS APNs bridge is wired. False
  /// when no `GoogleService-Info.plist` was found at startup — in that
  /// case every public method is a no-op.
  bool get isAvailable => _firebaseReady;

  /// Called from `main()`. Never throws — a missing Firebase config
  /// just disables push features for this run.
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    try {
      await Firebase.initializeApp();
      _fm = FirebaseMessaging.instance;
      _firebaseReady = true;
      _log.info('Firebase ready — APNs bridge available');

      // iOS: show the system banner / play sound / update badge even
      // when the app is foreground (otherwise iOS suppresses the
      // notification while DateNow is in front). The unread badge
      // pipeline stays independent and consistent.
      await _fm!.setForegroundNotificationPresentationOptions(
        alert: true,
        badge: true,
        sound: true,
      );

      // Token refresh — Apple may rotate the APNs token (reinstall,
      // restore, debug ↔ prod). Persist the new value automatically.
      _fm!.onTokenRefresh.listen(_persistToken);

      // Foreground tap → conversation deep link.
      FirebaseMessaging.onMessageOpenedApp.listen(_handleTap);

      // Cold-start: if the app was launched FROM a notification tap,
      // GetInitialMessage returns the payload synchronously.
      final initial = await _fm!.getInitialMessage();
      if (initial != null) _handleTap(initial);
    } catch (e, st) {
      _log.warn(
        'Firebase init skipped — push notifications disabled for this '
        'session ($e). Drop GoogleService-Info.plist into ios/Runner/ '
        'to enable.\n$st',
      );
    }
  }

  /// Request iOS notification permission + persist the APNs token.
  /// Called from the in-app permission sheet (first Messages tab open
  /// or first match). Returns `true` if the user granted and the token
  /// was stored.
  Future<bool> requestPermissionAndRegister() async {
    final fm = _fm;
    if (!_firebaseReady || fm == null) {
      _log.info('requestPermission ignored — Firebase not ready');
      return false;
    }
    final settings = await fm.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
    final granted =
        settings.authorizationStatus == AuthorizationStatus.authorized ||
            settings.authorizationStatus == AuthorizationStatus.provisional;
    _log.info(
      'requestPermission → ${settings.authorizationStatus.name}'
      ' (granted=$granted)',
    );
    if (!granted) return false;
    final token = await fm.getAPNSToken();
    if (token == null) {
      _log.warn('getAPNSToken returned null — token not registered');
      return false;
    }
    await _persistToken(token);
    return true;
  }

  /// Upserts the (user_id, token) pair into `public.device_tokens`.
  /// Owner-RLS handles the auth check server-side; an unauthenticated
  /// caller is silently dropped.
  Future<void> _persistToken(String token) async {
    try {
      final client = Supabase.instance.client;
      final userId = client.auth.currentUser?.id;
      if (userId == null) {
        _log.info('persistToken skipped — no signed-in user');
        return;
      }
      await client.from('device_tokens').upsert(
        {
          'user_id': userId,
          'platform': 'ios',
          'token': token,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
        onConflict: 'user_id,token',
      );
      _log.info(
        'persistToken upserted (token suffix=…${token.substring(token.length - 6)})',
      );
    } catch (e, st) {
      _log.warn('persistToken failed (will retry on refresh): $e\n$st');
    }
  }

  /// Removes this device's token on sign-out so the user stops
  /// receiving pushes on a device they no longer use.
  Future<void> unregister() async {
    final fm = _fm;
    if (!_firebaseReady || fm == null) return;
    try {
      final token = await fm.getAPNSToken();
      if (token == null) return;
      final client = Supabase.instance.client;
      final userId = client.auth.currentUser?.id;
      if (userId == null) return;
      await client
          .from('device_tokens')
          .delete()
          .eq('user_id', userId)
          .eq('token', token);
      _log.info('unregister: deleted token row');
    } catch (e) {
      _log.warn('unregister failed: $e');
    }
  }

  /// Pulls `conversation_id` out of the payload and pushes the
  /// conversation route. Robust to stale routes: if the deep-linked
  /// conversation can't be reached (signed out, wrong account…), the
  /// router redirect chain will land the user on the right screen.
  ///
  /// Cold start: getInitialMessage fires before the widget tree mounts,
  /// so rootNavigatorKey.currentContext is null. We retry on each frame
  /// (a few times) until the router is ready, then drop quietly.
  void _handleTap(RemoteMessage message, {int attempt = 0}) {
    final conversationId = message.data['conversation_id'] as String?;
    if (attempt == 0) {
      _log.info(
        'notification tap — conversation_id=${conversationId ?? '∅'}',
      );
    }
    if (conversationId == null) return;
    final context = rootNavigatorKey.currentContext;
    if (context != null) {
      context.pushNamed(
        AppRoute.conversation.name,
        pathParameters: {'id': conversationId},
      );
      return;
    }
    // Cold start: router not built yet. Retry on the next frame.
    // 30 frames at 60 Hz ≈ 500 ms — generous enough for splash redirect.
    if (attempt < 30) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _handleTap(message, attempt: attempt + 1),
      );
    } else {
      _log.warn('deep-link gave up after 30 frames — router never built');
    }
  }
}
