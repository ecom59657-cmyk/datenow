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

import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../app/router/app_router.dart';
import '../../app/router/app_routes.dart';
import '../utils/logger.dart';
import 'app_badge.dart';

class PushNotificationsService with WidgetsBindingObserver {
  PushNotificationsService._();

  static final PushNotificationsService instance =
      PushNotificationsService._();

  static const _log = AppLogger('Push');

  bool _initialized = false;

  /// The conversation the user is currently viewing, or null. Set by
  /// ConversationScreen so a foreground push for the open conversation can be
  /// marked read + cleared instead of lingering.
  String? _activeConversationId;

  /// Tells the service which conversation is on screen (null when none).
  void setActiveConversation(String? conversationId) {
    _activeConversationId = conversationId;
  }
  bool _firebaseReady = false;
  String? _lastInitError;
  FirebaseMessaging? _fm;

  /// MethodChannel exposed by `ios/Runner/SceneDelegate.swift`. The
  /// native side parses `embedded.mobileprovision` to read the actual
  /// `aps-environment` entitlement baked into the signed app — the only
  /// authoritative source for the APNs environment Apple will accept
  /// pushes for. `kReleaseMode` is NOT a reliable proxy: Xcode merges
  /// `Runner.entitlements` with the active provisioning profile at
  /// sign time, so a debug-built archive can ship with a production
  /// entitlement and vice-versa.
  static const MethodChannel _envChannel = MethodChannel('datenow/push_env');

  /// Resolved APNs environment for this app instance. Cached after the
  /// first successful native call. Used at upsert time so the Edge
  /// Function can route each push to the matching Apple host (sandbox
  /// vs production) — a sandbox token sent to prod (or vice-versa)
  /// returns `BadEnvironmentKeyInToken`.
  String? _apnsEnvironment;

  /// Best-effort current value (lazy — null before [initialize]).
  String? get apnsEnvironment => _apnsEnvironment;

  /// Reads the native `aps-environment` value once, caches it. On any
  /// failure (Android, missing handler, simulator quirks), falls back
  /// to `kReleaseMode` and logs a warning so it's visible in the
  /// console.
  Future<String> _resolveApnsEnvironment() async {
    final cached = _apnsEnvironment;
    if (cached != null) return cached;
    try {
      final result =
          await _envChannel.invokeMethod<String>('apnsEnvironment');
      if (result == 'development' || result == 'production') {
        _log.info('native aps-environment = $result');
        _apnsEnvironment = result;
        return result!;
      }
      _log.warn(
        'native aps-environment returned unexpected value "$result" — '
        'falling back to kReleaseMode',
      );
    } catch (e) {
      _log.warn(
        'native aps-environment call failed ($e) — falling back to '
        'kReleaseMode (this is expected on Android / non-iOS)',
      );
    }
    const fallback = kReleaseMode ? 'production' : 'development';
    _log.warn(
      'aps-environment fallback = $fallback (kReleaseMode=$kReleaseMode)',
    );
    _apnsEnvironment = fallback;
    return fallback;
  }

  /// True once Firebase is up and the iOS APNs bridge is wired. False
  /// when no `GoogleService-Info.plist` was found at startup — in that
  /// case every public method is a no-op.
  bool get isAvailable => _firebaseReady;

  /// Human-readable reason explaining why [isAvailable] is false (null
  /// when init succeeded or hasn't run yet). Useful for surfacing a
  /// "Push disabled because…" hint in a debug screen.
  String? get lastInitError => _lastInitError;

  /// Called from `main()`. Never throws — a missing Firebase config
  /// just disables push features for this run.
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    _log.info('init: starting Firebase + APNs bridge…');
    // Resolve the real aps-environment from the iOS bridge BEFORE any
    // token upsert so the first registration writes the correct value.
    final env = await _resolveApnsEnvironment();
    _log.info(
      'init: build flags (kReleaseMode=$kReleaseMode, '
      'kDebugMode=$kDebugMode, kProfileMode=$kProfileMode) — '
      'resolved apns_environment=$env',
    );
    try {
      await Firebase.initializeApp();
      _fm = FirebaseMessaging.instance;
      _firebaseReady = true;
      _log.info('init: Firebase ready — APNs bridge available');

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
      _fm!.onTokenRefresh.listen((t) {
        _log.info('onTokenRefresh fired');
        _persistToken(t);
      });

      // Foreground tap → conversation deep link.
      FirebaseMessaging.onMessageOpenedApp.listen(_handleTap);

      // Foreground message: if it's for the conversation already on screen,
      // mark it read + clear its delivered notification; always refresh the
      // app-icon badge to the real unread total.
      FirebaseMessaging.onMessage.listen(_handleForegroundMessage);

      // Recompute the badge whenever the app comes back to the foreground, so
      // it stays truthful even if reads happened on another device.
      WidgetsBinding.instance.addObserver(this);

      // Cold-start: if the app was launched FROM a notification tap,
      // GetInitialMessage returns the payload synchronously.
      final initial = await _fm!.getInitialMessage();
      if (initial != null) _handleTap(initial);

      // TEMP DEBUG — log the current APNs token at app open so you can
      // grep it from `flutter logs` / Xcode console and verify
      // device_tokens registration without an extra round-trip. REMOVE
      // before TestFlight public rollout. Grep marker: [TEMP-APNS-TOKEN]
      // ignore: discarded_futures
      _logCurrentTokenWithRetry();

      // Auto-register the current device on every signed-in event so a
      // user who already accepted notifications gets a fresh row in
      // device_tokens without having to open the Messages tab. This is
      // the cure for "permission authorized but device_tokens empty" —
      // see `maybeRegisterForSignedInUser` for the no-prompt path.
      Supabase.instance.client.auth.onAuthStateChange.listen((event) {
        if (event.event == AuthChangeEvent.signedIn ||
            event.event == AuthChangeEvent.tokenRefreshed ||
            event.event == AuthChangeEvent.initialSession) {
          // ignore: discarded_futures
          maybeRegisterForSignedInUser();
        }
      });
      // Also fire once now in case the session was already restored
      // before this listener attached.
      // ignore: discarded_futures
      maybeRegisterForSignedInUser();
    } catch (e, st) {
      _lastInitError = '$e';
      _log.warn(
        '╔════════════════════════════════════════════════════════════════╗\n'
        '║ FIREBASE INIT FAILED — push notifications disabled this run     ║\n'
        '╚════════════════════════════════════════════════════════════════╝\n'
        'Reason: $e\n'
        'Most likely cause: GoogleService-Info.plist not bundled in the iOS\n'
        'app (must be at ios/Runner/GoogleService-Info.plist AND referenced\n'
        'in Xcode under the Runner target → Copy Bundle Resources).\n'
        'Stack:\n$st',
      );
    }
  }

  /// Snapshot of the current iOS notification permission, without
  /// triggering a prompt. Returns null if Firebase isn't ready. Useful
  /// for deciding whether to show the in-app permission sheet.
  Future<AuthorizationStatus?> currentAuthorizationStatus() async {
    final fm = _fm;
    if (!_firebaseReady || fm == null) return null;
    try {
      final settings = await fm.getNotificationSettings();
      _log.info(
        'currentAuthorizationStatus = ${settings.authorizationStatus.name}',
      );
      return settings.authorizationStatus;
    } catch (e) {
      _log.warn('getNotificationSettings failed: $e');
      return null;
    }
  }

  /// Silent registration path: if the signed-in user has already
  /// granted iOS notification permission (e.g. previous install, or
  /// granted via the in-app sheet), make sure a fresh row exists in
  /// `device_tokens` for the current device. No iOS prompt is shown —
  /// `getNotificationSettings()` is read-only.
  ///
  /// Called automatically on every `signedIn` / `tokenRefreshed` /
  /// `initialSession` auth event, so the user doesn't have to open the
  /// Messages tab to get registered.
  Future<void> maybeRegisterForSignedInUser() async {
    final fm = _fm;
    if (!_firebaseReady || fm == null) return;
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) return;
    try {
      final settings = await fm.getNotificationSettings();
      final granted =
          settings.authorizationStatus == AuthorizationStatus.authorized ||
              settings.authorizationStatus == AuthorizationStatus.provisional;
      if (!granted) {
        _log.info(
          'maybeRegister: skipping — iOS status=${settings.authorizationStatus.name}',
        );
        return;
      }
      final token = await _getAPNSTokenWithRetry();
      if (token == null) {
        _log.warn('maybeRegister: getAPNSToken returned null');
        return;
      }
      _log.info(
        'maybeRegister: user=$userId is authorized → upserting token',
      );
      await _persistToken(token);
    } catch (e) {
      _log.warn('maybeRegister failed: $e');
    }
  }

  /// True if the signed-in user already has at least one row in
  /// `device_tokens`. Used by the inbox to re-prompt when the
  /// SharedPreferences "already asked" flag is stale (e.g. user denied,
  /// app reinstalled, token never landed in the DB).
  Future<bool> hasRegisteredTokenForCurrentUser() async {
    try {
      final client = Supabase.instance.client;
      final userId = client.auth.currentUser?.id;
      if (userId == null) return false;
      final rows = await client
          .from('device_tokens')
          .select('id')
          .eq('user_id', userId)
          .limit(1);
      final has = (rows as List).isNotEmpty;
      _log.info('hasRegisteredToken($userId) = $has');
      return has;
    } catch (e) {
      _log.warn('hasRegisteredToken failed: $e');
      return false;
    }
  }

  /// Request iOS notification permission + persist the APNs token.
  /// Called from the in-app permission sheet (first Messages tab open
  /// or first match) and from the Profile "Activer les notifications"
  /// row. Returns `true` if the user granted and the token was stored.
  Future<bool> requestPermissionAndRegister() async {
    final fm = _fm;
    if (!_firebaseReady || fm == null) {
      _log.warn(
        'requestPermission ignored — Firebase not ready '
        '(lastInitError=${_lastInitError ?? "n/a"})',
      );
      return false;
    }
    final settings = await fm.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
    final status = settings.authorizationStatus;
    final granted = status == AuthorizationStatus.authorized ||
        status == AuthorizationStatus.provisional;
    _log.info(
      'requestPermission → ${status.name} (granted=$granted, '
      'alert=${settings.alert.name}, sound=${settings.sound.name}, '
      'badge=${settings.badge.name})',
    );
    if (!granted) {
      switch (status) {
        case AuthorizationStatus.denied:
          _log.warn(
            'iOS reports DENIED. User must enable in Réglages → DateNow → '
            'Notifications (we cannot re-prompt programmatically).',
          );
        case AuthorizationStatus.notDetermined:
          _log.warn(
            'iOS reports NOT_DETERMINED after requestPermission — this is '
            'rare and usually means the system prompt failed to display '
            '(check that aps-environment is set in Runner.entitlements and '
            'that Push Notifications capability is enabled in Xcode).',
          );
        default:
          break;
      }
      return false;
    }

    // iOS may take a moment to assign the token after the user grants
    // permission. Retry a few times with backoff before giving up.
    final token = await _getAPNSTokenWithRetry();
    if (token == null) {
      _log.warn(
        'getAPNSToken returned null after retries. Likely causes:\n'
        '  • running on simulator (APNs unsupported)\n'
        '  • iOS Developer Mode not enabled on the device\n'
        '  • aps-environment entitlement missing from Runner.entitlements\n'
        '  • Push Notifications capability not enabled in Xcode\n'
        '  • Apple Developer Console: bundle id com.datenow.app has no '
        'Push Notifications capability\n',
      );
      return false;
    }
    await _persistToken(token);
    return true;
  }

  /// Poll `getAPNSToken()` a handful of times because iOS sometimes
  /// returns null right after `registerForRemoteNotifications` and
  /// resolves a second or two later.
  Future<String?> _getAPNSTokenWithRetry() async {
    final fm = _fm;
    if (fm == null) return null;
    for (var attempt = 1; attempt <= 6; attempt++) {
      try {
        final token = await fm.getAPNSToken();
        if (token != null && token.isNotEmpty) {
          _log.info(
            'getAPNSToken success on attempt $attempt (len=${token.length})',
          );
          return token;
        }
        _log.info('getAPNSToken attempt $attempt → null, retrying…');
      } catch (e) {
        _log.warn('getAPNSToken attempt $attempt threw: $e');
      }
      await Future<void>.delayed(Duration(milliseconds: 500 * attempt));
    }
    return null;
  }

  /// Upserts the (user_id, token) pair into `public.device_tokens`.
  /// Owner-RLS handles the auth check server-side; an unauthenticated
  /// caller is silently dropped.
  Future<void> _persistToken(String token) async {
    try {
      final client = Supabase.instance.client;
      final userId = client.auth.currentUser?.id;
      if (userId == null) {
        _log.warn(
          'persistToken skipped — no signed-in Supabase user. Token will '
          'be re-tried on the next onTokenRefresh or sign-in.',
        );
        return;
      }
      final env = await _resolveApnsEnvironment();
      final response = await client
          .from('device_tokens')
          .upsert(
            {
              'user_id': userId,
              'platform': 'ios',
              'apns_environment': env,
              'token': token,
              'updated_at': DateTime.now().toUtc().toIso8601String(),
            },
            onConflict: 'user_id,token',
          )
          .select('id, user_id, apns_environment, updated_at')
          .maybeSingle();
      _log.info(
        'persistToken upserted user=$userId env=$env '
        'suffix=…${token.substring(token.length - 6)} '
        'row=$response',
      );
      // TEMP DEBUG — also log the FULL token so it can be copied straight
      // out of `flutter logs` / Xcode console for end-to-end testing.
      // REMOVE before TestFlight public rollout. Grep: [TEMP-APNS-TOKEN]
      _log.warn('[TEMP-APNS-TOKEN] $token');
    } on PostgrestException catch (e, st) {
      _log.warn(
        'persistToken Postgrest error: code=${e.code} '
        'message=${e.message} details=${e.details}\n$st',
      );
    } catch (e, st) {
      _log.warn('persistToken failed (${e.runtimeType}): $e\n$st');
    }
  }

  /// TEMP DEBUG — fetches and logs the current APNs token at app open.
  /// iOS may take a couple of seconds to assign the token after
  /// `registerForRemoteNotifications`, so we retry a few times. Silent
  /// no-op if the user never granted permission. REMOVE before public
  /// rollout. Grep marker: [TEMP-APNS-TOKEN]
  Future<void> _logCurrentTokenWithRetry() async {
    final fm = _fm;
    if (!_firebaseReady || fm == null) return;
    for (var attempt = 0; attempt < 5; attempt++) {
      try {
        final token = await fm.getAPNSToken();
        if (token != null) {
          _log.warn(
            '[TEMP-APNS-TOKEN] app-open (attempt ${attempt + 1}): $token',
          );
          return;
        }
      } catch (_) {
        // ignore — APNs may not be registered yet
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    _log.info(
      '[TEMP-APNS-TOKEN] app-open — token still null after 5 retries '
      '(permission likely not granted yet)',
    );
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

  /// Foreground push handler. iOS still shows the banner (presentation options
  /// keep alert on for other conversations), but if the message is for the
  /// conversation already on screen we mark it read + clear its delivered
  /// notification so nothing lingers. The badge is always recomputed.
  void _handleForegroundMessage(RemoteMessage message) {
    final convId = message.data['conversation_id'] as String?;
    _log.info(
      'onMessage (foreground) conv=${convId ?? '∅'} '
      'active=${_activeConversationId ?? '∅'}',
    );
    if (convId != null && convId == _activeConversationId) {
      unawaited(_markConversationRead(convId));
      unawaited(AppBadge.clearConversation(convId));
    }
    unawaited(refreshBadge());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    unawaited(refreshBadge());
    final convId = _activeConversationId;
    if (convId != null) unawaited(AppBadge.clearConversation(convId));
  }

  /// Recomputes the app-icon badge from the REAL unread total
  /// (`unread_messages_count()` RPC) and pushes it to iOS. Safe no-op when
  /// signed out or Supabase is unavailable.
  Future<void> refreshBadge() async {
    try {
      final client = Supabase.instance.client;
      if (client.auth.currentUser == null) return;
      final res = await client.rpc<dynamic>('unread_messages_count');
      final count = res is int
          ? res
          : (res is num ? res.toInt() : 0);
      await AppBadge.setCount(count);
      _log.info('refreshBadge → $count');
    } catch (e) {
      _log.warn('refreshBadge failed (ignored): $e');
    }
  }

  /// Marks every incoming message of [conversationId] read server-side
  /// (`mark_conversation_read` RPC, participant-checked).
  Future<void> _markConversationRead(String conversationId) async {
    try {
      await Supabase.instance.client.rpc<dynamic>(
        'mark_conversation_read',
        params: {'p_conversation_id': conversationId},
      );
    } catch (e) {
      _log.warn('mark_conversation_read($conversationId) failed: $e');
    }
  }
}
