// Release-safety guards (Test 8).
//
// Static source-level assertions — they fail the build if a debug
// surface, a sensitive log or an Agora secret leaks into the shippable
// code. These run in plain `flutter test` and need no device.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Test 8 — debug / release safety', () {
    test('debug routes are gated on kDebugMode in the router', () {
      final src = File('lib/app/router/app_router.dart').readAsStringSync();

      // Each debug GoRoute must have an `if (kDebugMode)` guard in the
      // ~150 chars immediately preceding its path reference, so it is not
      // registered at all in a release build.
      for (final route in ['debugDateNow', 'debugMatching']) {
        final idx = src.indexOf('AppRoute.$route.path');
        expect(idx, greaterThan(-1), reason: '$route route missing');
        final window = src.substring((idx - 150).clamp(0, idx), idx);
        expect(window.contains('if (kDebugMode)'), isTrue,
            reason: '$route must sit under an `if (kDebugMode)` guard');
      }
    });

    test('AppLogger output is gated on kDebugMode', () {
      final src = File('lib/core/utils/logger.dart').readAsStringSync();
      expect(src.contains('if (!kDebugMode) return;'), isTrue,
          reason: 'logs must never run in release');
    });

    test('no AGORA_APP_CERTIFICATE reference anywhere in lib/', () {
      final offenders = <String>[];
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is File && entity.path.endsWith('.dart')) {
          if (entity.readAsStringSync().contains('AGORA_APP_CERTIFICATE')) {
            offenders.add(entity.path);
          }
        }
      }
      expect(offenders, isEmpty,
          reason: 'the Agora certificate must stay server-side only');
    });

    test('the Agora token model never exposes the raw token to Debug', () {
      // AgoraTokenDebugInfo is the struct the Debug screen renders — it
      // must carry only non-sensitive diagnostics, never the token string.
      final src =
          File('lib/features/call/data/agora_token_repository.dart')
              .readAsStringSync();
      final debugStart = src.indexOf('class AgoraTokenDebugInfo');
      final debugEnd = src.indexOf('}', debugStart);
      final debugClass = src.substring(debugStart, debugEnd);
      expect(debugClass.contains('token'), isFalse,
          reason: 'AgoraTokenDebugInfo must not hold the token string');
    });
  });
}
