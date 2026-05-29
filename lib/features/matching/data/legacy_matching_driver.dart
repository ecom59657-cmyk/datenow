import '../../call/data/call_session_repository.dart';
import 'matching_driver.dart';
import 'matchmaking_repository.dart';

/// V1 implementation of [MatchingDriver].
///
/// Pure delegation to [MatchmakingRepository] — i.e. the same RPC
/// surface the matching screen called directly before the driver
/// abstraction was introduced. The class deliberately adds **no**
/// behaviour of its own : when `FeatureFlags.useMatchingV2` is `false`
/// (the dormant default), this driver IS the active path and runtime
/// behaviour must be strictly identical to the pre-flag commit.
///
/// The V2-only methods ([acceptMatch], [declineMatch],
/// [cancelSession]) are no-ops here — V1's `claim_match` was atomic,
/// so there was no separate consent / decline / hangup step at the
/// matching-queue layer. Keeping them as no-ops lets future
/// post-match screens call them unconditionally without branching on
/// the active engine.
class LegacyMatchingDriver implements MatchingDriver {
  const LegacyMatchingDriver(this._repo);

  final MatchmakingRepository _repo;

  @override
  String get name => 'V1';

  @override
  Future<void> joinQueue(String userId) => _repo.joinQueue(userId);

  @override
  Future<void> leaveQueue(String userId) => _repo.leaveQueue(userId);

  @override
  Future<void> heartbeat() => _repo.heartbeat();

  @override
  Future<Map<String, dynamic>?> selfQueueRow(String userId) =>
      _repo.selfQueueRow(userId);

  @override
  Future<LiveCandidateResult> findBestLiveCandidateV1({
    required String selfId,
    int minScore = 50,
  }) =>
      _repo.findBestLiveCandidateV1(selfId: selfId, minScore: minScore);

  @override
  Future<CallSessionRow> claimMatch(String peerId) =>
      _repo.claimMatch(peerId);

  @override
  Stream<CallSessionRow?> watchMyActiveCall(String selfId) =>
      _repo.watchMyActiveCall(selfId);

  // ── V2-only surface: no-ops on V1 ───────────────────────────────

  @override
  Future<void> acceptMatch(String callId) async {
    // V1 has no consent step — claim_match was atomic. Returning
    // success here lets the post-match path stay engine-agnostic.
  }

  @override
  Future<void> declineMatch(String callId, {String? reason}) async {}

  @override
  Future<void> cancelSession(
    String callId, {
    String reason = 'user_cancel',
  }) async {
    // Hangup on V1 is owned by `CallSessionRepository`. Returning
    // success here keeps the engine-agnostic facade alive — callers
    // routing through a driver under V1 don't need to special-case.
  }
}
