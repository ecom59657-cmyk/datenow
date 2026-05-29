import '../../call/data/call_session_repository.dart';
import 'matchmaking_repository.dart';

/// Strategy interface fronting the live-matching engine.
///
/// The matching screen depends ONLY on this abstraction; the concrete
/// engine is selected by `matchingDriverProvider` based on
/// `FeatureFlags.useMatchingV2`:
///
/// * [LegacyMatchingDriver] — the original V1 path, calls the
///   `find_best_live_candidate_v1` SQL RPC and the `claim_match` RPC
///   directly through [MatchmakingRepository]. **Default**, used when
///   `MATCHING_V2 = false` (the dormant state).
/// * [V2MatchingDriver] — the new Edge-Function path
///   (`join-queue`, `find-match`, …). Built but **not** wired by
///   default; activated only via the [FallbackMatchingDriver] when
///   `MATCHING_V2 = true`.
/// * [FallbackMatchingDriver] — when V2 is active, wraps a V2 driver
///   with a V1 driver as automatic fallback: any V2 method throw is
///   caught and the same operation is retried on V1, so a misbehaving
///   Edge Function never bricks the matching flow for the user.
///
/// Re-exports `LiveCandidateResult` from [MatchmakingRepository] so
/// the screen can keep its rejection-reason switch unchanged when
/// the driver changes engines.
abstract class MatchingDriver {
  /// Stable diagnostic identifier surfaced in `[MATCHING V?]` logs
  /// and in the test reports. Suggested values: `'V1'`, `'V2'`,
  /// `'V2+V1-fallback'`.
  String get name;

  /// Inserts (or refreshes) the user's row in the live-matching queue.
  /// V1: upserts into `matchmaking_queue`. V2: posts `/join-queue`.
  Future<void> joinQueue(String userId);

  /// Removes the user from the queue. Idempotent on both engines.
  /// V1: `DELETE matchmaking_queue WHERE user_id = X`.
  /// V2: posts `/leave-queue`.
  Future<void> leaveQueue(String userId);

  /// Refreshes the heartbeat / presence freshness window. Silent
  /// no-op when the caller has no queue row.
  /// V1: `queue_heartbeat` RPC. V2: `/heartbeat-presence`.
  Future<void> heartbeat();

  /// Diagnostic helper — does the **caller** currently have a row in
  /// the queue? V1 implementation issues a `SELECT … WHERE user_id =
  /// auth.uid()` to prove the upsert actually persisted (caught the
  /// silent-RLS class of bugs in the S1 session). V2 returns a
  /// synthetic confirmation because `/join-queue` already validated
  /// server-side and returns an explicit error on failure — no need
  /// to re-query.
  Future<Map<String, dynamic>?> selfQueueRow(String userId);

  /// Returns the best-scoring candidate above [minScore] for the
  /// caller, or a structured rejection when nothing matches.
  ///
  /// V1: invokes the `find_best_live_candidate_v1` SQL RPC. The body
  /// already returns a [LiveCandidateResult] shape.
  ///
  /// V2: invokes the `find-match` Edge Function and normalises its
  /// response into a [LiveCandidateResult]. When V2 matches, the
  /// resulting `calls` row is already created server-side — the
  /// driver remembers its `call_id` so the subsequent [claimMatch]
  /// can return the existing row instead of creating a duplicate.
  Future<LiveCandidateResult> findBestLiveCandidateV1({
    required String selfId,
    int minScore = 50,
  });

  /// Pairs the caller with [peerId]. V1: atomic `claim_match` RPC —
  /// CREATES the `calls` row and removes both users from queue. V2:
  /// the call was already created by [findBestLiveCandidateV1] (which
  /// internally hits `mm_find_match`), so this method just returns
  /// the stored row.
  Future<CallSessionRow> claimMatch(String peerId);

  /// Realtime stream of the user's active call. Both engines watch
  /// the same `calls` table so the realtime contract is identical.
  Stream<CallSessionRow?> watchMyActiveCall(String selfId);

  // ── V2-only surface ────────────────────────────────────────────
  // V1 has no equivalent for the three methods below — its
  // `claim_match` flow is atomic so there is no separate consent
  // step. The legacy driver implements them as no-ops so a future
  // post-call screen can call them unconditionally regardless of
  // the active engine.

  /// Flips the caller's `ready` flag on the proposed call. Once
  /// both participants are ready, the call transitions to `live`.
  /// V2: `/accept-match`. V1: no-op (claim was atomic).
  Future<void> acceptMatch(String callId);

  /// Refuses the proposed match. The peer is re-injected in queue.
  /// V2: `/decline-match`. V1: no-op (no consent step).
  Future<void> declineMatch(String callId, {String? reason});

  /// Cancels a `waiting` or `live` session — hangup from inside the
  /// call screen or a late teardown. V2: `/cancel-session`. V1: the
  /// caller is expected to use [CallSessionRepository] directly.
  Future<void> cancelSession(String callId, {String reason = 'user_cancel'});
}
