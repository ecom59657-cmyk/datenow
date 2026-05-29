import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/debug/debug_observer.dart';
import '../../../core/services/supabase_service.dart';
import '../../../core/utils/logger.dart';
import '../../call/data/call_session_repository.dart';

/// Real-time matchmaking queue backed by `public.matchmaking_queue`.
///
/// A user "searching" inserts their row; clients read the queue to find
/// peers, score them with [MatchingService] client-side, then call the
/// `claim_match` RPC which atomically pairs two users and spawns the
/// shared `calls` (video session) row.
class MatchmakingRepository {
  MatchmakingRepository(this._client);

  final SupabaseClient _client;
  static const _log = AppLogger('MATCHING V1');
  static const _queueTable = 'matchmaking_queue';

  /// Enters the queue. Upsert keeps it idempotent if the user re-taps
  /// "search" without having left first.
  ///
  /// Logs are intentionally noisy so a TestFlight S1 failure ("row never
  /// appears in matchmaking_queue") can be diagnosed from the console
  /// alone — we surface :
  ///   • the auth session UID vs the userId arg (RLS gate),
  ///   • the PostgREST representation actually returned by the upsert
  ///     (forced via `.select().maybeSingle()` so a silent RLS refusal
  ///     surfaces as `null`),
  ///   • a typed [PostgrestException] when the server actually rejects
  ///     the call (code + message + details).
  Future<void> joinQueue(String userId) async {
    final session = _client.auth.currentSession;
    final sessionUid = session?.user.id;
    final tokenExpired = session?.isExpired ?? true;
    _log.info(
      'joinQueue START userId=$userId sessionUid=$sessionUid '
      'tokenExpired=$tokenExpired',
    );
    if (sessionUid == null) {
      _log.error(
        'joinQueue ABORT — no auth session client-side. RLS will deny. '
        'Vérifie supabase.auth.currentSession et le restore session.',
      );
      throw StateError('joinQueue: no auth session');
    }
    if (sessionUid != userId) {
      _log.error(
        'joinQueue ABORT — sessionUid ($sessionUid) != userId ($userId). '
        'WITH CHECK mq_modify_own va refuser. Mismatch profil vs auth.',
      );
      throw StateError('joinQueue: auth/userId mismatch');
    }
    DebugLog.match('joinQueue'); // debug-observer
    try {
      final inserted = await _client
          .from(_queueTable)
          .upsert({'user_id': userId}, onConflict: 'user_id')
          .select()
          .maybeSingle();
      if (inserted == null) {
        _log.error(
          'joinQueue UPSERT returned NULL — likely silent RLS refusal. '
          'Vérifie la policy mq_modify_own et que sessionUid == auth.uid().',
        );
      } else {
        _log.info(
          'joinQueue UPSERT ok — row id=${inserted['id']} '
          'user_id=${inserted['user_id']} '
          'created_at=${inserted['created_at']} '
          'heartbeat_at=${inserted['heartbeat_at']} '
          'expires_at=${inserted['expires_at']}',
        );
      }
    } on PostgrestException catch (e) {
      _log.error(
        'joinQueue PostgrestException — code=${e.code} '
        'message=${e.message} hint=${e.hint} details=${e.details}',
        e,
      );
      rethrow;
    }
  }

  /// Diagnostic helper — does the **caller** currently have a row in the
  /// queue? Bypasses the [active_queue_peers] RPC (which excludes self
  /// by design) so we can prove the upsert actually persisted.
  ///
  /// Returns `null` if the row is missing (sweep / RLS), or the row's
  /// `(heartbeat_at, expires_at)` pair when present.
  Future<Map<String, dynamic>?> selfQueueRow(String userId) async {
    final res = await _client
        .from(_queueTable)
        .select('user_id, heartbeat_at, expires_at')
        .eq('user_id', userId)
        .maybeSingle();
    _log.info(
      'selfQueueRow userId=$userId → ${res ?? 'MISSING'}',
    );
    return res;
  }

  /// Leaves the queue. Safe to call when not queued.
  Future<void> leaveQueue(String userId) async {
    _log.info('leaveQueue user=$userId');
    await _client.from(_queueTable).delete().eq('user_id', userId);
  }

  /// Refreshes the caller's queue heartbeat (server clock). Called on a
  /// ~12 s cadence while the search screen is open so peers can tell the
  /// caller is still actively searching.
  ///
  /// `queue_heartbeat` is `SECURITY DEFINER` and UPDATEs `WHERE
  /// user_id = auth.uid()` — it returns void and never raises when the
  /// caller has no row in the queue (silent 0-row update). We log every
  /// invocation so a TestFlight S1 dump can confirm the RPC is at least
  /// reaching the server, and catch `PostgrestException` typed to surface
  /// the rare cases where it does fail (auth missing, network).
  Future<void> heartbeat() async {
    try {
      await _client.rpc<dynamic>('queue_heartbeat');
      _log.info('queue_heartbeat RPC ok (silent — no return value)');
    } on PostgrestException catch (e) {
      _log.error(
        'queue_heartbeat PostgrestException — code=${e.code} '
        'message=${e.message} hint=${e.hint} details=${e.details}',
        e,
      );
      rethrow;
    }
  }

  /// User ids of peers currently searching with a *fresh* heartbeat
  /// (< 30 s). Server-side filtered — a crashed / backgrounded client's
  /// stale row is ignored automatically and never blocks a match.
  Future<Set<String>> fetchQueueUserIds(String selfId) async {
    final res = await _client.rpc<dynamic>('active_queue_peers');
    final ids = (res as List).map((e) => e as String).toSet();
    _log.info('queue has ${ids.length} active peer(s)');
    return ids;
  }

  /// Calls the express server-side matching RPC `find_best_live_candidate_v1`.
  /// Returns a typed result with either a chosen `candidateId` + score
  /// breakdown + real PostGIS distance, or a `rejectionReason` when no
  /// match exists. Replaces the old client-side
  /// `fetchPotentialCandidates + calculateCompatibility(distanceKm: 10)`
  /// loop — see migration 20260526170000_find_best_live_candidate_v1.sql.
  Future<LiveCandidateResult> findBestLiveCandidateV1({
    required String selfId,
    int minScore = 50,
  }) async {
    final res = await _client.rpc<dynamic>(
      'find_best_live_candidate_v1',
      params: {'p_self_id': selfId, 'p_min_score': minScore},
    );
    // Postgres functions returning TABLE come back as a List of Maps.
    if (res is! List || res.isEmpty) {
      throw StateError(
        'find_best_live_candidate_v1 returned unexpected payload: $res',
      );
    }
    final row = (res.first as Map).cast<String, dynamic>();
    final result = LiveCandidateResult.fromJson(row);
    if (result.candidateId != null) {
      _log.info(
        'find_best_live_candidate_v1 → ${result.candidateId} '
        'score=${result.totalScore}/100 dist=${result.distanceM}m '
        '(d=${result.scoreDistance} i=${result.scoreInterests} '
        'a=${result.scoreAge} f=${result.scoreFreshness}) '
        'eligible=${result.candidatesEvaluated} queue=${result.queueSize}',
      );
    } else {
      _log.info(
        'find_best_live_candidate_v1 → no match — '
        'reason=${result.rejectionReason} '
        'eligible=${result.candidatesEvaluated} queue=${result.queueSize}',
      );
    }
    return result;
  }

  /// Atomically claims [peerId] as a match. The server creates (or reuses)
  /// the shared `calls` row, derives its `channel_name`, and removes both
  /// users from the queue. Returns the session row.
  ///
  /// Throws if the peer already left the queue (claimed by someone else).
  Future<CallSessionRow> claimMatch(String peerId) async {
    _log.info('claimMatch peer=$peerId');
    final res = await _client.rpc<dynamic>(
      'claim_match',
      params: {'peer_id': peerId},
    );
    if (res is! Map) {
      throw StateError('claim_match returned unexpected payload: $res');
    }
    final row = CallSessionRow.fromJson(res.cast<String, dynamic>());
    _log.info('claimMatch ok — callId=${row.id} channel=${row.channelName}');
    DebugLog.match('claimMatch ok call=${row.id}'); // debug-observer
    return row;
  }

  /// Streams the caller's active (non-ended) call. Fires when a peer
  /// claims *this* user — so the searching screen can react even when it
  /// wasn't the one to run `claimMatch`.
  Stream<CallSessionRow?> watchMyActiveCall(String selfId) async* {
    final stream = _client
        .from('calls')
        .stream(primaryKey: ['id']);
    await for (final rows in stream) {
      CallSessionRow? mine;
      for (final raw in rows) {
        final r = CallSessionRow.fromJson(raw);
        final isParticipant = r.callerId == selfId || r.calleeId == selfId;
        if (isParticipant && !r.isEnded) {
          mine = r;
          break;
        }
      }
      yield mine;
    }
  }
}

/// Typed result of `find_best_live_candidate_v1`. Either:
///   * `candidateId != null` → matched candidate with full breakdown,
///   * `candidateId == null` → `rejectionReason` explains why.
///
/// Always carries `candidatesEvaluated` and `queueSize` for debug logs.
class LiveCandidateResult {
  const LiveCandidateResult({
    required this.candidateId,
    required this.totalScore,
    required this.scoreDistance,
    required this.scoreInterests,
    required this.scoreAge,
    required this.scoreFreshness,
    required this.distanceM,
    required this.rejectionReason,
    required this.candidatesEvaluated,
    required this.queueSize,
  });

  final String? candidateId;
  final int? totalScore;
  final int? scoreDistance;
  final int? scoreInterests;
  final int? scoreAge;
  final int? scoreFreshness;
  final int? distanceM;
  final String? rejectionReason;
  final int candidatesEvaluated;
  final int queueSize;

  factory LiveCandidateResult.fromJson(Map<String, dynamic> json) {
    int? toInt(Object? v) => v == null ? null : (v as num).toInt();
    return LiveCandidateResult(
      candidateId: json['candidate_id'] as String?,
      totalScore: toInt(json['total_score']),
      scoreDistance: toInt(json['score_distance']),
      scoreInterests: toInt(json['score_interests']),
      scoreAge: toInt(json['score_age']),
      scoreFreshness: toInt(json['score_freshness']),
      distanceM: toInt(json['distance_m']),
      rejectionReason: json['rejection_reason'] as String?,
      candidatesEvaluated: toInt(json['candidates_evaluated']) ?? 0,
      queueSize: toInt(json['queue_size']) ?? 0,
    );
  }
}

final matchmakingRepositoryProvider =
    Provider<MatchmakingRepository?>((ref) {
  if (!ref.watch(supabaseAvailableProvider)) return null;
  return MatchmakingRepository(ref.watch(supabaseClientProvider));
});
