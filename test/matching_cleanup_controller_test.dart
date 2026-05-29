// Unit tests for the [MatchingCleanupController] invariant.
//
// These tests sandbox the three exit paths the matching screen has —
// user cancel, framework dispose, app lifecycle pause — and verify
// that no matter which order they fire, `leaveQueue` runs at most
// once and `setIntent(online)` runs at most once.
//
// The controller is intentionally pure-Dart (no Flutter widget, no
// Riverpod ProviderScope, no Supabase client) precisely so this
// invariant can be tested without `WidgetTester` boilerplate.
//
// Maps to user-facing cases :
//   * Cas 1 (back navigation) ......... `cancel → dispose` sequence
//   * Cas 3 (app paused / detached) ... `lifecycle:* → dispose` sequence
//   * Cas 4 (cancel button) ........... `cancel → dispose` sequence
//   * Match success ................... `matched=true` skip
//
// See lib/features/matching/presentation/matching_cleanup_controller.dart
// for the production code under test.

import 'package:datenow/features/matching/presentation/matching_cleanup_controller.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tiny spy/closure pair the tests build to count the two side-effects
/// the controller emits. Lives at top-level so each test can build a
/// fresh instance without leaking counters between assertions.
class _CleanupSpy {
  int leaveCount = 0;
  int presenceCount = 0;
  bool leaveShouldThrow = false;
  bool presenceShouldThrow = false;
  final List<String> logs = [];

  MatchingCleanupController build() {
    return MatchingCleanupController(
      leaveQueue: () async {
        if (leaveShouldThrow) {
          throw StateError('simulated leaveQueue network failure');
        }
        leaveCount++;
      },
      resetPresence: () {
        if (presenceShouldThrow) {
          throw StateError('simulated presence write failure');
        }
        presenceCount++;
      },
      logger: logs.add,
    );
  }
}

void main() {
  group('MatchingCleanupController — Cas 1/3/4 invariants', () {
    test(
      'Cas 4 — cancel button then framework dispose: leaveQueue runs once',
      () async {
        final spy = _CleanupSpy();
        final ctrl = spy.build();

        await ctrl.run(matched: false, trigger: 'cancel');
        await ctrl.run(matched: false, trigger: 'dispose');

        expect(spy.leaveCount, 1, reason: 'leaveQueue must be idempotent');
        expect(spy.presenceCount, 1,
            reason: 'setIntent(online) must be idempotent');
        expect(ctrl.hasRun, isTrue);
      },
    );

    test(
      'Cas 3 — lifecycle:paused then dispose: cleanup runs once at pause',
      () async {
        final spy = _CleanupSpy();
        final ctrl = spy.build();

        await ctrl.run(matched: false, trigger: 'lifecycle:paused');
        await ctrl.run(matched: false, trigger: 'dispose');

        expect(spy.leaveCount, 1);
        expect(spy.presenceCount, 1);
        // Verify the first-fired trigger is the one that actually ran.
        expect(
          spy.logs.where((l) => l.contains('cleanup running')).single,
          contains('lifecycle:paused'),
        );
      },
    );

    test(
      'Cas 3 — lifecycle:detached pathway also triggers cleanup',
      () async {
        final spy = _CleanupSpy();
        final ctrl = spy.build();

        await ctrl.run(matched: false, trigger: 'lifecycle:detached');

        expect(spy.leaveCount, 1);
        expect(spy.presenceCount, 1);
      },
    );

    test(
      'Cas 1/4 — three rapid triggers stack to one cleanup',
      () async {
        // Simulates the worst-case race: user taps cancel, system back
        // gesture overrides at the same time, app gets backgrounded
        // mid-pop. All three fire teardown in the same micro-tick.
        final spy = _CleanupSpy();
        final ctrl = spy.build();

        // Fire all three without awaiting between to mimic the race.
        final futures = [
          ctrl.run(matched: false, trigger: 'cancel'),
          ctrl.run(matched: false, trigger: 'lifecycle:paused'),
          ctrl.run(matched: false, trigger: 'dispose'),
        ];
        await Future.wait(futures);

        expect(spy.leaveCount, 1,
            reason: 'three concurrent triggers must still leave once');
        expect(spy.presenceCount, 1);
        expect(ctrl.hasRun, isTrue);
      },
    );

    test(
      'matched=true skips cleanup AND does not flip the flag',
      () async {
        // A successful claim_match removes both users server-side, so
        // the client must NOT leaveQueue again (idempotent on the
        // wire, but log noise) and must NOT reset presence (the call
        // screen owns presence state from this point).
        final spy = _CleanupSpy();
        final ctrl = spy.build();

        await ctrl.run(matched: true, trigger: 'dispose');

        expect(spy.leaveCount, 0);
        expect(spy.presenceCount, 0);
        expect(ctrl.hasRun, isFalse,
            reason: 'flag must stay false so a later legitimate '
                'unmatched call can still run');
      },
    );

    test(
      'matched=true first, then matched=false later: cleanup still runs once',
      () async {
        // Edge case: peer claims us via realtime mid-search, _match
        // gets set to non-null briefly, then the call session ends
        // before MatchingScreen tears down. _match goes back to null
        // (in practice impossible but defensive). Cleanup should still
        // perform its single run.
        final spy = _CleanupSpy();
        final ctrl = spy.build();

        await ctrl.run(matched: true, trigger: 'matched-peek');
        expect(spy.leaveCount, 0);

        await ctrl.run(matched: false, trigger: 'dispose');
        expect(spy.leaveCount, 1);
        expect(spy.presenceCount, 1);
      },
    );

    test(
      'leaveQueue throw does NOT prevent presence reset',
      () async {
        // Cas 3 + offline: app paused while iPhone has no network.
        // leaveQueue throws (no internet) — we must still reset
        // presence client-side so the user isn't stuck "searching"
        // on resume of the UI.
        final spy = _CleanupSpy()..leaveShouldThrow = true;
        final ctrl = spy.build();

        await ctrl.run(matched: false, trigger: 'lifecycle:paused');

        expect(spy.leaveCount, 0,
            reason: 'leaveQueue threw before counter bumped');
        expect(spy.presenceCount, 1,
            reason: 'presence reset must run despite the throw');
        expect(ctrl.hasRun, isTrue,
            reason: 'subsequent triggers should still see "ran" and bail');
      },
    );

    test(
      'presence throw is also swallowed (best-effort throughout)',
      () async {
        final spy = _CleanupSpy()..presenceShouldThrow = true;
        final ctrl = spy.build();

        // Should not propagate the throw to the caller — dispose can't
        // accept exceptions.
        await ctrl.run(matched: false, trigger: 'dispose');

        expect(spy.leaveCount, 1);
        expect(spy.presenceCount, 0);
        expect(ctrl.hasRun, isTrue);
      },
    );

    test(
      'log lines are emitted in the expected order',
      () async {
        final spy = _CleanupSpy();
        final ctrl = spy.build();

        await ctrl.run(matched: false, trigger: 'cancel');
        await ctrl.run(matched: false, trigger: 'dispose');
        await ctrl.run(matched: true, trigger: 'matched-peek');

        // 1 "running" line for cancel
        // 1 "ignored (already ran)" line for dispose
        // 1 "ignored (already ran)" line for matched-peek
        // (the matched check comes after the _ran check)
        expect(spy.logs, [
          'cleanup running trigger=cancel',
          'cleanup ignored (already ran) trigger=dispose',
          'cleanup ignored (already ran) trigger=matched-peek',
        ]);
      },
    );
  });
}
