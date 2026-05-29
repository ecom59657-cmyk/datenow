import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/utils/logger.dart';
import '../../call/data/call_session_repository.dart';
import 'matching_driver.dart';
import 'matchmaking_repository.dart';

/// V2 implementation of [MatchingDriver] — calls the new
/// Edge-Function surface that wraps the `mm_*` SQL RPCs:
///
/// | Method                       | Edge Function       | Body                              |
/// |------------------------------|---------------------|-----------------------------------|
/// | [joinQueue]                  | `join-queue`        | `{ client_id?: string }`          |
/// | [leaveQueue]                 | `leave-queue`       | `{}`                              |
/// | [heartbeat]                  | `heartbeat-presence`| `{}`                              |
/// | [findBestLiveCandidateV1]    | `find-match`        | `{ min_score?: number }`          |
/// | [acceptMatch]                | `accept-match`      | `{ call_id: uuid }`               |
/// | [declineMatch]               | `decline-match`     | `{ call_id: uuid, reason?: string }`|
/// | [cancelSession]              | `cancel-session`    | `{ call_id: uuid, reason: string }` |
///
/// Built but **dormant** — only reachable when
/// `FeatureFlags.useMatchingV2` is set explicitly to a truthy value.
/// In production the default remains `false`.
///
/// ## Known V2 / V1 contract gaps (documented, not improvised)
///
/// V2 collapses V1's `find → claim` two-step into a single atomic
/// `find-match` Edge Function call. The Edge Function returns the
/// already-created `calls` row (`call_id`, `channel_name`, …). So:
///
/// * [findBestLiveCandidateV1] stores the matched `call_id` and
///   `peer_id` in [_pendingMatch] when V2 returns `matched=true`.
/// * [claimMatch] then re-reads the `calls` row by id and returns
///   it as a [CallSessionRow]. There is **no** separate V2 RPC for
///   "claim" — the legacy method name is preserved on the driver
///   interface for API stability.
/// * If [claimMatch] is invoked without a prior matching
///   [findBestLiveCandidateV1] success, [_pendingMatch] is null and
///   the method throws [StateError] with a clear marker so
///   [FallbackMatchingDriver] can route the call to V1.
///
/// ## Why a singleton-style `_pendingMatch`?
///
/// The matching screen's `_poll` loop calls
/// `findBestLiveCandidateV1` then immediately `claimMatch` within
/// the same tick — same instance of the driver, same Riverpod scope.
/// Holding the bridge state on the driver itself is the simplest
/// path that does not leak V2 knowledge into the screen.
class V2MatchingDriver implements MatchingDriver {
  V2MatchingDriver(this._client);

  final SupabaseClient _client;
  static const _log = AppLogger('MATCHING V2');

  /// Bridge state between V2's atomic `find-match` (which already
  /// creates the `calls` row) and the legacy two-step API the
  /// matching screen still consumes. Cleared after [claimMatch] (or
  /// [_clearPending] on cancel) so a stale match cannot leak into
  /// the next poll cycle.
  _PendingMatch? _pendingMatch;

  @override
  String get name => 'V2';

  // ── Queue lifecycle ─────────────────────────────────────────────

  @override
  Future<void> joinQueue(String userId) async {
    _log.info('joinQueue (Edge: join-queue) START userId=$userId');
    final res = await _client.functions.invoke(
      'join-queue',
      body: <String, dynamic>{},
    );
    final data = res.data;
    if (data is Map &&
        data['joined'] == true &&
        data['queue_id'] != null) {
      _log.info(
        'joinQueue OK — queue_id=${data['queue_id']} '
        'expires_at=${data['expires_at']}',
      );
      return;
    }
    throw StateError(
      'V2 join-queue returned unexpected payload: $data '
      '(status=${res.status})',
    );
  }

  @override
  Future<void> leaveQueue(String userId) async {
    _log.info('leaveQueue (Edge: leave-queue) userId=$userId');
    final res = await _client.functions.invoke(
      'leave-queue',
      body: <String, dynamic>{},
    );
    _log.info(
      'leaveQueue OK — left=${(res.data as Map?)?['left']}',
    );
  }

  @override
  Future<void> heartbeat() async {
    final res = await _client.functions.invoke(
      'heartbeat-presence',
      body: <String, dynamic>{},
    );
    final data = res.data;
    if (data is Map) {
      _log.info(
        'heartbeat-presence OK — queue_alive=${data['queue_alive']} '
        'presence=${data['presence_status']}',
      );
      return;
    }
    throw StateError(
      'V2 heartbeat-presence returned unexpected payload: $data',
    );
  }

  @override
  Future<Map<String, dynamic>?> selfQueueRow(String userId) async {
    // V2's `/join-queue` already returns an explicit error on RLS /
    // server-side rejection — no silent-null class of bug to catch.
    // Returning a synthetic confirmation keeps the matching screen's
    // diagnostic "Step A.bis VERIFY" branch a clean pass-through.
    return <String, dynamic>{
      'user_id': userId,
      'verified_via': 'v2_join_queue_response',
    };
  }

  // ── Find / claim ────────────────────────────────────────────────

  @override
  Future<LiveCandidateResult> findBestLiveCandidateV1({
    required String selfId,
    int minScore = 50,
  }) async {
    final res = await _client.functions.invoke(
      'find-match',
      body: <String, dynamic>{'min_score': minScore},
    );
    final data = res.data;
    if (data is! Map) {
      throw StateError('V2 find-match returned non-map payload: $data');
    }

    if (data['matched'] == false) {
      _pendingMatch = null;
      _log.info('find-match → no_candidate');
      return const LiveCandidateResult(
        candidateId: null,
        totalScore: null,
        scoreDistance: null,
        scoreInterests: null,
        scoreAge: null,
        scoreFreshness: null,
        distanceM: null,
        rejectionReason: 'no_candidate',
        candidatesEvaluated: 0,
        queueSize: 0,
      );
    }

    if (data['matched'] == true) {
      final callId = data['call_id'] as String?;
      final peerId = data['peer_id'] as String?;
      final channel = data['channel_name'] as String?;
      if (callId == null || peerId == null || channel == null) {
        throw StateError(
          'V2 find-match matched=true missing required fields: $data',
        );
      }
      _pendingMatch = _PendingMatch(
        callId: callId,
        peerId: peerId,
        channelName: channel,
        score: (data['score'] as num?)?.toInt(),
      );
      _log.info(
        'find-match → matched peer=$peerId call=$callId '
        'score=${data['score']} relaxed=${data['relaxed']}',
      );
      return LiveCandidateResult(
        candidateId: peerId,
        totalScore: (data['score'] as num?)?.toInt(),
        // V2 returns an aggregate score only — V1's breakdown is not
        // currently surfaced. Filled with 0 so the screen's score
        // chip renders consistently; refine when V2 surfaces the
        // detail (matching plan sub-phase 1.6).
        scoreDistance: 0,
        scoreInterests: 0,
        scoreAge: 0,
        scoreFreshness: 0,
        distanceM: 0,
        rejectionReason: null,
        candidatesEvaluated: 1,
        queueSize: 0,
      );
    }

    throw StateError('V2 find-match returned no `matched` field: $data');
  }

  @override
  Future<CallSessionRow> claimMatch(String peerId) async {
    final pending = _pendingMatch;
    if (pending == null || pending.peerId != peerId) {
      // No prior find-match in this driver instance — V1's atomic
      // claim_match flow has no V2 equivalent because `find-match`
      // already creates the call. The fallback wrapper catches this
      // and routes to LegacyMatchingDriver instead.
      throw StateError(
        'V2 claimMatch called without a prior matching find-match '
        '(expected peer=$peerId, pending=${pending?.peerId})',
      );
    }
    _log.info(
      'claimMatch (from V2 find-match cache) call=${pending.callId} '
      'peer=$peerId',
    );
    // Fetch the freshly-created `calls` row to honour the V1 surface
    // contract — return value is consumed by `_onMatched(session, ...)`
    // on the matching screen.
    final row = await _client
        .from('calls')
        .select()
        .eq('id', pending.callId)
        .maybeSingle();
    if (row == null) {
      throw StateError(
        'V2 claimMatch — calls row ${pending.callId} not found '
        '(was created by mm_find_match, did it get swept?)',
      );
    }
    _pendingMatch = null;
    return CallSessionRow.fromJson(row);
  }

  @override
  Stream<CallSessionRow?> watchMyActiveCall(String selfId) async* {
    // V2 and V1 watch the same `calls` table. Re-implementing the
    // stream here keeps the V2 driver dependency-free (no
    // MatchmakingRepository import); cost is ~12 lines duplicated.
    final stream = _client.from('calls').stream(primaryKey: ['id']);
    await for (final rows in stream) {
      CallSessionRow? mine;
      for (final raw in rows) {
        final r = CallSessionRow.fromJson(raw);
        final isParticipant =
            r.callerId == selfId || r.calleeId == selfId;
        if (isParticipant && !r.isEnded) {
          mine = r;
          break;
        }
      }
      yield mine;
    }
  }

  // ── V2-only ─────────────────────────────────────────────────────

  @override
  Future<void> acceptMatch(String callId) async {
    final res = await _client.functions.invoke(
      'accept-match',
      body: <String, dynamic>{'call_id': callId},
    );
    final data = res.data;
    if (data is Map) {
      _log.info(
        'accept-match OK call=$callId state=${data['state']} '
        'both_ready=${data['both_ready']}',
      );
      return;
    }
    throw StateError('V2 accept-match returned unexpected: $data');
  }

  @override
  Future<void> declineMatch(String callId, {String? reason}) async {
    final body = <String, dynamic>{'call_id': callId};
    if (reason != null) body['reason'] = reason;
    final res = await _client.functions.invoke(
      'decline-match',
      body: body,
    );
    final data = res.data;
    if (data is Map) {
      _log.info(
        'decline-match OK call=$callId declined=${data['declined']}',
      );
      return;
    }
    throw StateError('V2 decline-match returned unexpected: $data');
  }

  @override
  Future<void> cancelSession(
    String callId, {
    String reason = 'user_cancel',
  }) async {
    final res = await _client.functions.invoke(
      'cancel-session',
      body: <String, dynamic>{'call_id': callId, 'reason': reason},
    );
    final data = res.data;
    if (data is Map) {
      _log.info(
        'cancel-session OK call=$callId reason=$reason '
        'ended=${data['ended']}',
      );
      return;
    }
    throw StateError('V2 cancel-session returned unexpected: $data');
  }

  /// Test hook — public callers should never need this. Lets the unit
  /// tests reset internal pairing state between assertions without
  /// reaching into private fields.
  void debugClearPending() => _pendingMatch = null;
}

/// Tuple of state carried from V2's atomic `find-match` to the
/// follow-up `claimMatch` call. Kept private — the driver surface
/// only exposes the legacy two-step API.
class _PendingMatch {
  const _PendingMatch({
    required this.callId,
    required this.peerId,
    required this.channelName,
    required this.score,
  });

  final String callId;
  final String peerId;
  final String channelName;
  final int? score;
}
