// Source-level guard on the post-call waiting screen, in the same spirit as
// release_safety_test.dart.
//
// The trap this protects against: leaving the waiting screen used to be
// wired straight to `_pass()`, which writes `revealed: false` — an
// irreversible refusal presented as a way off a screen. If the peer said
// yes thirty seconds later, the match was already gone and nobody could
// tell why. The stage itself needs two live peers to exercise, so this
// asserts the wiring rather than the behaviour.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String src;

  setUpAll(() {
    src = File('lib/features/post_call/presentation/post_call_screen.dart')
        .readAsStringSync();
  });

  group('post-call waiting exits', () {
    test('the waiting view never wires a button straight to _pass', () {
      final waitingView = src.substring(src.indexOf('_Stage.waiting => _WaitingView('));
      final wiring = waitingView.substring(0, waitingView.indexOf('),\n'));
      expect(
        wiring.contains('_pass'),
        isFalse,
        reason: 'the irreversible refusal must go through a confirmation',
      );
      expect(wiring, contains('onDecline: _declineExplicitly'));
      expect(wiring, contains('onComeBackLater: _comeBackLater'));
    });

    test('declining asks first', () {
      final body = src.substring(
        src.indexOf('Future<void> _declineExplicitly()'),
        src.indexOf('Future<void> _declineExplicitly()') + 700,
      );
      expect(body, contains('showDestructiveConfirm'));
      // The confirmation has to gate the call, not follow it.
      expect(
        body.indexOf('showDestructiveConfirm'),
        lessThan(body.indexOf('_pass()')),
      );
    });

    test('coming back later writes nothing to reveals', () {
      final body = src.substring(
        src.indexOf('void _comeBackLater()'),
        src.indexOf('void _comeBackLater()') + 500,
      );
      expect(
        body.contains('submitReveal'),
        isFalse,
        reason: 'leaving must keep the reveal open, not decline it',
      );
      expect(
        body.contains('recordDecision'),
        isFalse,
        reason: 'leaving must keep the reveal open, not decline it',
      );
    });

    test('the waiting window cannot be re-armed forever', () {
      expect(src, contains('_waitRearmCount >= _maxRearms'));
      expect(src, contains('static const _maxRearms'));
    });
  });
}
