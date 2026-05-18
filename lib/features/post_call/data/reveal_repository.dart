import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/services/supabase_service.dart';
import '../../../core/utils/logger.dart';

/// One participant's post-call decision.
class RevealRow {
  const RevealRow({
    required this.callId,
    required this.userId,
    required this.revealed,
  });

  final String callId;
  final String userId;
  final bool revealed;

  factory RevealRow.fromJson(Map<String, dynamic> json) {
    return RevealRow(
      callId: json['call_id'] as String,
      userId: json['user_id'] as String,
      revealed: json['revealed'] as bool? ?? false,
    );
  }
}

/// Mutual outcome of a call's reveal phase.
enum RevealOutcome {
  /// Not enough decisions in yet.
  pending,

  /// Both participants chose to reveal — unlock photo + create match.
  mutual,

  /// At least one participant passed — no match.
  declined,
}

/// Backs the post-call reveal: records each user's decision in
/// `public.reveals` and (when both reveal) writes the permanent
/// `public.matches` row.
class RevealRepository {
  RevealRepository(this._client);

  final SupabaseClient _client;
  static const _log = AppLogger('Reveal');

  /// Records (or updates) the current user's decision for [callId].
  Future<void> submitReveal({
    required String callId,
    required String userId,
    required bool revealed,
  }) async {
    _log.info('submitReveal call=$callId user=$userId revealed=$revealed');
    await _client.from('reveals').upsert(
      {
        'call_id': callId,
        'user_id': userId,
        'revealed': revealed,
      },
      onConflict: 'call_id,user_id',
    );
  }

  /// Streams every reveal row for [callId] (this user's + the peer's).
  Stream<List<RevealRow>> watchReveals(String callId) {
    return _client
        .from('reveals')
        .stream(primaryKey: ['id'])
        .eq('call_id', callId)
        .map((rows) => rows.map(RevealRow.fromJson).toList());
  }

  /// Resolves the mutual outcome given the reveal rows and the two
  /// expected participant ids.
  RevealOutcome outcomeFor(
    List<RevealRow> rows, {
    required String selfId,
    required String peerId,
  }) {
    RevealRow? mine;
    RevealRow? theirs;
    for (final r in rows) {
      if (r.userId == selfId) mine = r;
      if (r.userId == peerId) theirs = r;
    }
    // A `revealed = false` row means an explicit pass.
    if (mine?.revealed == false || theirs?.revealed == false) {
      return RevealOutcome.declined;
    }
    if (mine?.revealed == true && theirs?.revealed == true) {
      return RevealOutcome.mutual;
    }
    return RevealOutcome.pending;
  }

  /// Creates the permanent match row. Idempotent: the table's
  /// UNIQUE(user_a_id, user_b_id) + ordered-pair CHECK mean a second
  /// caller (the peer reaching `mutual` at the same time) upserts the
  /// same row instead of duplicating it.
  Future<void> createMatch({
    required String callId,
    required String userA,
    required String userB,
    required int compatibilityScore,
  }) async {
    // The table requires user_a_id < user_b_id.
    final ordered = [userA, userB]..sort();
    _log.info(
      'createMatch — pair=${ordered.first}/${ordered.last} '
      'call=$callId score=$compatibilityScore',
    );
    await _client.from('matches').upsert(
      {
        'user_a_id': ordered.first,
        'user_b_id': ordered.last,
        'compatibility_score': compatibilityScore.clamp(0, 100),
        'call_id': callId,
        'status': 'new',
      },
      onConflict: 'user_a_id,user_b_id',
    );
  }
}

final revealRepositoryProvider = Provider<RevealRepository?>((ref) {
  if (!ref.watch(supabaseAvailableProvider)) return null;
  return RevealRepository(ref.watch(supabaseClientProvider));
});

/// Holds the id of the call the user is currently in / just finished.
/// Set by [CallScreen] when the session opens; read by the post-call
/// reveal screen so it knows which `calls` row the reveals attach to.
final activeCallIdProvider = StateProvider<String?>((ref) => null);
