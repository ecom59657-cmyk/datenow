/// Idempotent teardown for a single live-matching session.
///
/// The Matching V1 screen has three exit paths that all need to leave
/// `matchmaking_queue` exactly once and reset presence to `online`
/// exactly once:
///
///   * **Cancel button** — user taps `×` or the explicit `_cancel()`
///     path. Calls `pop()` which then triggers framework `dispose()`.
///   * **Framework dispose** — back gesture, router replace, parent
///     rebuild, hot restart.
///   * **App lifecycle pause** — iPhone home button, app switcher.
///     A `WidgetsBindingObserver` fires `didChangeAppLifecycleState`
///     for `paused` / `detached`.
///
/// Without a guard each path duplicates `repo.leaveQueue(...)` +
/// `presence.setIntent(online)`. The server tolerates duplicates
/// (DELETE-WHERE is idempotent, presence is a write) but the log
/// noise + duplicate network roundtrips muddle TestFlight diagnostics
/// — the exact reason `[MATCHING V1]` lines exist in the first place.
///
/// This controller owns the "did we already exit" flag and the two
/// teardown callbacks. It is constructed by the matching screen in
/// `initState` and consulted at every exit site. Lives outside the
/// widget so the invariant can be unit-tested without a `WidgetTester`
/// or a `ProviderScope` (see test/matching_cleanup_controller_test.dart).
class MatchingCleanupController {
  MatchingCleanupController({
    required this.leaveQueue,
    required this.resetPresence,
    this.logger,
  });

  /// Closure that calls `MatchmakingRepository.leaveQueue(self.userId)`.
  /// Awaited so a failure does not silently swallow.
  final Future<void> Function() leaveQueue;

  /// Closure that flips the user's presence back to `online`. Sync —
  /// presence controller writes are fire-and-forget by design.
  final void Function() resetPresence;

  /// Optional sink for diagnostic strings — populated with `_log.info`
  /// in production, with `print` (or nothing) in tests.
  final void Function(String message)? logger;

  bool _ran = false;

  /// True once a real teardown has executed. Stays false if every call
  /// to [run] saw `matched = true` (a successful match takes the queue
  /// row down server-side via `claim_match`, so we deliberately skip).
  bool get hasRun => _ran;

  /// Idempotent. First call with `matched = false` invokes
  /// [leaveQueue] then [resetPresence]. All subsequent calls — for
  /// any [trigger] — are no-ops. Calls with `matched = true` are
  /// skipped without flipping the flag (so a stray paused → resumed
  /// → cancel sequence after a successful match remains harmless).
  ///
  /// [trigger] is purely for diagnostics. Suggested values:
  /// `'cancel'`, `'dispose'`, `'lifecycle:paused'`,
  /// `'lifecycle:detached'`.
  Future<void> run({
    required bool matched,
    required String trigger,
  }) async {
    if (_ran) {
      logger?.call('cleanup ignored (already ran) trigger=$trigger');
      return;
    }
    if (matched) {
      logger?.call('cleanup skipped (matched=true) trigger=$trigger');
      return;
    }
    _ran = true;
    logger?.call('cleanup running trigger=$trigger');
    try {
      await leaveQueue();
    } catch (e, st) {
      logger?.call('leaveQueue threw: $e\n$st');
      // Swallow — best-effort. The presence reset still runs and the
      // server-side sweep will clear the row within 30 s anyway.
    }
    try {
      resetPresence();
    } catch (e, st) {
      logger?.call('resetPresence threw: $e\n$st');
    }
  }

}
