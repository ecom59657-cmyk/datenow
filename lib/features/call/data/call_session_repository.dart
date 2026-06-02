import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

import '../../../core/debug/debug_observer.dart';
import '../../../core/services/supabase_service.dart';
import '../../../core/utils/logger.dart';

/// Minimal row snapshot the client cares about — `status` drives the
/// shared lifecycle and `ended_by` lets the UI tell who hung up.
class CallSessionRow {
  const CallSessionRow({
    required this.id,
    required this.callerId,
    required this.calleeId,
    required this.status,
    required this.endedBy,
    required this.channelName,
    required this.startedAt,
    required this.callerReady,
    required this.calleeReady,
  });

  final String id;
  final String callerId;
  final String calleeId;
  final String status; // 'waiting' | 'live' | 'ended'
  final String? endedBy;
  final String? channelName;

  /// Server timestamp the call row was created. Both peers read the same
  /// value, so a countdown derived from it stays coherent across devices
  /// and survives a screen refresh / re-join.
  final DateTime startedAt;

  /// Pre-call handshake flags. Each peer flips its own once its CallScreen
  /// is mounted; the video only joins when [bothReady] is true.
  final bool callerReady;
  final bool calleeReady;

  bool get isEnded => status == 'ended';

  /// True once both participants have signalled their CallScreen is up.
  bool get bothReady => callerReady && calleeReady;

  /// Whether [meUserId]'s peer has marked itself ready.
  bool peerReady(String meUserId) =>
      meUserId == callerId ? calleeReady : callerReady;

  /// True when [meUserId] was *not* the one who ended the call (i.e. the
  /// peer hung up first). Lets the local UI tear down without prompting
  /// the user to confirm an action they didn't take.
  bool endedByPeer(String meUserId) => isEnded && endedBy != null && endedBy != meUserId;

  factory CallSessionRow.fromJson(Map<String, dynamic> json) {
    final startedRaw = json['started_at'] as String?;
    return CallSessionRow(
      id: json['id'] as String,
      callerId: json['caller_id'] as String,
      calleeId: json['callee_id'] as String,
      status: json['status'] as String? ?? 'live',
      endedBy: json['ended_by'] as String?,
      channelName: json['channel_name'] as String?,
      startedAt: startedRaw != null
          ? DateTime.parse(startedRaw).toUtc()
          : DateTime.now().toUtc(),
      callerReady: json['caller_ready'] as bool? ?? false,
      calleeReady: json['callee_ready'] as bool? ?? false,
    );
  }
}

/// Coordinates the shared lifecycle of a 1-1 call across two clients.
///
/// Each user calls [open] when their CallScreen mounts. The first peer
/// creates the row; the second peer (with the same `channelName`) reuses
/// it. When either peer calls [end], `status` flips to `'ended'` and the
/// peer's [watch] subscription fires so their UI can tear down too.
class CallSessionRepository {
  CallSessionRepository(this._client);

  final sb.SupabaseClient _client;
  static const _log = AppLogger('CallSession');
  static const _table = 'calls';

  /// Returns the active call row for the (a, b) participant pair (either
  /// direction), if any.
  Future<CallSessionRow?> _findActiveForPair(
    String userIdA,
    String userIdB,
  ) async {
    final rows = await _client
        .from(_table)
        .select()
        .or(
          'and(caller_id.eq.$userIdA,callee_id.eq.$userIdB),'
          'and(caller_id.eq.$userIdB,callee_id.eq.$userIdA)',
        )
        .neq('status', 'ended')
        .order('started_at', ascending: false)
        .limit(1);
    if (rows.isEmpty) return null;
    return CallSessionRow.fromJson(rows.first);
  }

  /// Opens (or joins) the shared call session between [meUserId] and
  /// [peerUserId].
  ///
  /// Lookup happens by **participant pair**, not by channel name, so the
  /// two clients converge on the same row even if their local matching
  /// picks slightly different orderings. The first peer to call `open`
  /// inserts the row and writes the deterministic `channel_name`; the
  /// second peer finds that row and reads the same channel_name from it.
  ///
  /// Returns the row plus a `source` field so the caller can log whether
  /// the call was freshly created or reused from an existing row.
  Future<({CallSessionRow row, String source})> open({
    required String meUserId,
    required String peerUserId,
  }) async {
    _log.info('open meUserId=$meUserId peer=$peerUserId');

    final existing = await _findActiveForPair(meUserId, peerUserId);
    if (existing != null) {
      _log.info(
        'fetched existing call id=${existing.id} '
        'channel=${existing.channelName} status=${existing.status}',
      );
      return (row: existing, source: 'fetched_existing');
    }

    // V1 Hardening (Pass 5 H2) :
    // The legacy two-step INSERT-then-UPDATE pattern is gone. Direct
    // INSERT into `calls` is now blocked by RLS (commit 4 dropped
    // the FOR ALL policy and replaced it with SELECT/UPDATE-only).
    //
    // We call the SECURITY DEFINER RPC `create_call_for_discover`
    // which validates the caller server-side (auth, identity gate,
    // ban check, mutual block, no concurrent call) and writes the
    // row with id + channel_name in a single statement. The
    // canonical channel-name pattern (`dn_<id>`) is preserved
    // unchanged — only the call site moves.
    //
    // Race handling : if the peer just created the row a tick
    // before us, the RPC raises `already_in_call` (SQLSTATE 23P01).
    // We catch it and fall back to `_findActiveForPair`, which is
    // exactly what the pre-V1-hardening code did when its INSERT
    // hit the UNIQUE-active-pair index.
    try {
      final created = await _client.rpc<dynamic>(
        'create_call_for_discover',
        params: {'p_peer_id': peerUserId},
      );
      // RPC returns a single calls row (SETOF calls). Supabase wraps
      // it as a single-element list for `RETURNS public.calls`.
      final Map<String, dynamic> row =
          (created is List && created.isNotEmpty)
              ? (created.first as Map).cast<String, dynamic>()
              : (created as Map).cast<String, dynamic>();
      _log.info(
        'created call id=${row['id']} channel=${row['channel_name']}',
      );
      DebugLog.call('call created ${row['id']}');
      return (row: CallSessionRow.fromJson(row), source: 'created');
    } on sb.PostgrestException catch (e) {
      // 23P01 already_in_call : a concurrent peer just won the race.
      // Re-fetch the row they created.
      if (e.code == '23P01') {
        _log.info(
          'create_call_for_discover lost race vs peer — re-fetching',
        );
        final raced = await _findActiveForPair(meUserId, peerUserId);
        if (raced != null) {
          return (row: raced, source: 'fetched_existing');
        }
      }
      // 23505 UNIQUE active pair : same outcome, race lost.
      if (e.code == '23505') {
        final raced = await _findActiveForPair(meUserId, peerUserId);
        if (raced != null) {
          return (row: raced, source: 'fetched_existing');
        }
      }
      rethrow;
    }
  }

  /// Flips the caller's own pre-call ready flag. The `mark_call_ready`
  /// RPC picks the right column (caller/callee) from auth.uid(), so a
  /// client can never mark its peer ready. Idempotent.
  Future<void> markReady(String callId) async {
    _log.info('markReady call=$callId');
    await _client.rpc<dynamic>(
      'mark_call_ready',
      params: {'p_call_id': callId},
    );
  }

  /// Marks the call ended. Idempotent — calling twice does nothing harmful.
  Future<void> end({
    required String callId,
    required String byUserId,
  }) async {
    _log.info('end call=$callId by=$byUserId');
    await _client.from(_table).update({
      'status': 'ended',
      'ended_at': DateTime.now().toUtc().toIso8601String(),
      'ended_by': byUserId,
    }).eq('id', callId).neq('status', 'ended');
  }

  /// Streams updates to a specific call row via Supabase Realtime. The
  /// initial value (fetched once) is yielded first so subscribers see the
  /// current state immediately; subsequent updates arrive as the row is
  /// patched server-side.
  Stream<CallSessionRow> watch(String callId) async* {
    final initial = await _client
        .from(_table)
        .select()
        .eq('id', callId)
        .maybeSingle();
    if (initial != null) {
      yield CallSessionRow.fromJson(initial);
    }
    final stream = _client
        .from(_table)
        .stream(primaryKey: ['id'])
        .eq('id', callId);
    await for (final rows in stream) {
      if (rows.isEmpty) continue;
      yield CallSessionRow.fromJson(rows.first);
    }
  }
}

/// Available only when Supabase is configured. Features that depend on a
/// shared session (currently: the call screen end-sync) should gate on
/// [supabaseAvailableProvider] before reading this.
final callSessionRepositoryProvider =
    Provider<CallSessionRepository?>((ref) {
  if (!ref.watch(supabaseAvailableProvider)) return null;
  return CallSessionRepository(ref.watch(supabaseClientProvider));
});

/// Current pre-call handshake phase, surfaced for the Debug screen.
/// One of: `idle`, `opening`, `waiting_peer_ready`, `joining_call`,
/// `live`, `ended`.
final precallStateProvider = StateProvider<String>((_) => 'idle');
