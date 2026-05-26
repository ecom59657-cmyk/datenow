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
  static const _log = AppLogger('Matchmaking');
  static const _queueTable = 'matchmaking_queue';

  /// Enters the queue. Upsert keeps it idempotent if the user re-taps
  /// "search" without having left first.
  Future<void> joinQueue(String userId) async {
    _log.info('joinQueue user=$userId');
    DebugLog.match('joinQueue'); // debug-observer
    await _client.from(_queueTable).upsert(
      {'user_id': userId},
      onConflict: 'user_id',
    );
  }

  /// Leaves the queue. Safe to call when not queued.
  Future<void> leaveQueue(String userId) async {
    _log.info('leaveQueue user=$userId');
    await _client.from(_queueTable).delete().eq('user_id', userId);
  }

  /// Refreshes the caller's queue heartbeat (server clock). Called on a
  /// ~12 s cadence while the search screen is open so peers can tell the
  /// caller is still actively searching.
  Future<void> heartbeat() async {
    await _client.rpc<dynamic>('queue_heartbeat');
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
