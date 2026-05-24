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

    test('post-call reveal loads the peer photo, not the current user\'s', () {
      // Regression guard for the MVP bug where _loadPeerPhoto() read
      // `currentProfileProvider` and showed the user their own face at
      // reveal. The fix must: (a) read the peer id from activeMatch,
      // (b) go through profileRepositoryProvider, (c) never reach for
      // currentProfileProvider inside this method.
      final src = File(
        'lib/features/post_call/presentation/post_call_screen.dart',
      ).readAsStringSync();
      final start = src.indexOf('Future<void> _loadPeerPhoto()');
      expect(start, greaterThan(-1), reason: '_loadPeerPhoto missing');
      // Bound the window at the next method declaration so adjacent code
      // (which legitimately uses currentProfileProvider) is excluded.
      final end = src.indexOf('  void _', start + 1);
      expect(end, greaterThan(start), reason: 'next method after _loadPeerPhoto not found');
      final body = src.substring(start, end);

      expect(body.contains('currentProfileProvider'), isFalse,
          reason:
              '_loadPeerPhoto must not read the current user — that is the '
              'bug that showed the tester their own photo at reveal.');
      expect(body.contains('activeMatchProvider'), isTrue,
          reason: '_loadPeerPhoto must read the peer id from activeMatch');
      expect(body.contains('profileRepositoryProvider'), isTrue,
          reason: '_loadPeerPhoto must fetch through profileRepository');
    });

    test('ReportReason wire values match the server reports_reason_check', () {
      // The 7 enum wire strings must exist verbatim inside the
      // reports_reason_check CHECK constraint, otherwise an insert from
      // the report sheet 400s with a constraint violation.
      final dartSrc = File(
        'lib/features/safety/domain/report_reason.dart',
      ).readAsStringSync();
      final sqlSrc = File(
        'supabase/migrations/20260524120000_app_store_compliance.sql',
      ).readAsStringSync();

      // Constrain to the CHECK block so we don't accidentally match
      // free-form text earlier in the file.
      final checkStart = sqlSrc.indexOf("reports_reason_check");
      expect(checkStart, greaterThan(-1), reason: 'CHECK block missing');
      final checkEnd = sqlSrc.indexOf("));", checkStart);
      final checkBlock = sqlSrc.substring(checkStart, checkEnd);

      const wires = [
        'inappropriate_behavior',
        'nudity_sexual',
        'harassment',
        'minor',
        'fake_profile',
        'spam',
        'other',
      ];
      for (final w in wires) {
        expect(dartSrc.contains("'$w'"), isTrue,
            reason: 'Dart ReportReason missing wire $w');
        expect(checkBlock.contains("'$w'"), isTrue,
            reason: 'SQL CHECK missing wire $w');
      }
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
