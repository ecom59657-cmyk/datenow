import '../../../core/utils/logger.dart';
import '../../call/data/call_session_repository.dart';
import 'matching_driver.dart';
import 'matchmaking_repository.dart';

/// Composes a [primary] driver with a [fallback] driver: every method
/// tries [primary] first; on throw, the exception is logged and the
/// same operation is retried on [fallback]. If [fallback] also throws,
/// the second exception propagates.
///
/// Built for the V2 rollout: `primary = V2MatchingDriver`,
/// `fallback = LegacyMatchingDriver`. If any V2 Edge Function is
/// unreachable, returns an unexpected payload, or hits one of the
/// known contract gaps (e.g. `claimMatch` without a prior
/// `find-match`), the user transparently lands on the V1 path
/// without seeing a SnackBar.
///
/// **Caveat documented**: V2's `find-match` collapses V1's `find +
/// claim` into a single atomic step. If a V2 `findBestLiveCandidateV1`
/// **succeeds** and then `claimMatch` is routed to V1, the V1 RPC
/// will fail because the peer is no longer in queue (V2 already
/// removed them). A future PR should track which engine answered
/// the find call and route the matching claim to the same engine.
/// For dormant V2 (`FeatureFlags.useMatchingV2 = false`) this is
/// unreachable; flagged for the activation PR.
class FallbackMatchingDriver implements MatchingDriver {
  FallbackMatchingDriver({
    required this.primary,
    required this.fallback,
  });

  final MatchingDriver primary;
  final MatchingDriver fallback;
  static const _log = AppLogger('MATCHING V2');

  @override
  String get name => '${primary.name}+${fallback.name}-fallback';

  Future<T> _tryThenFallback<T>(
    String op,
    Future<T> Function() primaryCall,
    Future<T> Function() fallbackCall,
  ) async {
    try {
      return await primaryCall();
    } catch (e, st) {
      _log.warn(
        '$op on ${primary.name} threw — falling back to ${fallback.name}: $e',
      );
      // Stack trace kept on the warn for TestFlight log dump.
      _log.warn('$op stacktrace:\n$st');
      return fallbackCall();
    }
  }

  @override
  Future<void> joinQueue(String userId) => _tryThenFallback(
        'joinQueue',
        () => primary.joinQueue(userId),
        () => fallback.joinQueue(userId),
      );

  @override
  Future<void> leaveQueue(String userId) => _tryThenFallback(
        'leaveQueue',
        () => primary.leaveQueue(userId),
        () => fallback.leaveQueue(userId),
      );

  @override
  Future<void> heartbeat() => _tryThenFallback(
        'heartbeat',
        () => primary.heartbeat(),
        () => fallback.heartbeat(),
      );

  @override
  Future<Map<String, dynamic>?> selfQueueRow(String userId) =>
      _tryThenFallback(
        'selfQueueRow',
        () => primary.selfQueueRow(userId),
        () => fallback.selfQueueRow(userId),
      );

  @override
  Future<LiveCandidateResult> findBestLiveCandidateV1({
    required String selfId,
    int minScore = 50,
  }) =>
      _tryThenFallback(
        'findBestLiveCandidateV1',
        () => primary.findBestLiveCandidateV1(
          selfId: selfId,
          minScore: minScore,
        ),
        () => fallback.findBestLiveCandidateV1(
          selfId: selfId,
          minScore: minScore,
        ),
      );

  @override
  Future<CallSessionRow> claimMatch(String peerId) => _tryThenFallback(
        'claimMatch',
        () => primary.claimMatch(peerId),
        () => fallback.claimMatch(peerId),
      );

  @override
  Stream<CallSessionRow?> watchMyActiveCall(String selfId) {
    // Streams are not retry-on-throw — they emit errors over time
    // rather than throwing on subscription. Prefer the primary
    // stream; if subscription itself throws, fall back. Long-running
    // emissions are not switched mid-flight.
    try {
      return primary.watchMyActiveCall(selfId);
    } catch (e) {
      _log.warn(
        'watchMyActiveCall on ${primary.name} throw — '
        'using ${fallback.name}: $e',
      );
      return fallback.watchMyActiveCall(selfId);
    }
  }

  @override
  Future<void> acceptMatch(String callId) => _tryThenFallback(
        'acceptMatch',
        () => primary.acceptMatch(callId),
        () => fallback.acceptMatch(callId),
      );

  @override
  Future<void> declineMatch(String callId, {String? reason}) =>
      _tryThenFallback(
        'declineMatch',
        () => primary.declineMatch(callId, reason: reason),
        () => fallback.declineMatch(callId, reason: reason),
      );

  @override
  Future<void> cancelSession(
    String callId, {
    String reason = 'user_cancel',
  }) =>
      _tryThenFallback(
        'cancelSession',
        () => primary.cancelSession(callId, reason: reason),
        () => fallback.cancelSession(callId, reason: reason),
      );
}
