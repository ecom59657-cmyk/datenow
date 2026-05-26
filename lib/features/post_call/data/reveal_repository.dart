import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/services/supabase_service.dart';
import '../../../core/utils/logger.dart';

/// One participant's post-call decision. Two distinct pieces of state:
///  * [revealed] — did the user opt to show their photo to the peer?
///  * [decision] — *after* mutual reveal, did the user pick Match or Pass?
///    ('pending' until they tap one of the two buttons.)
class RevealRow {
  const RevealRow({
    required this.callId,
    required this.userId,
    required this.revealed,
    required this.decision,
  });

  final String callId;
  final String userId;
  final bool revealed;
  final String decision; // 'pending' | 'match' | 'pass'

  factory RevealRow.fromJson(Map<String, dynamic> json) {
    return RevealRow(
      callId: json['call_id'] as String,
      userId: json['user_id'] as String,
      revealed: json['revealed'] as bool? ?? false,
      decision: (json['decision'] as String?) ?? 'pending',
    );
  }
}

/// Mutual outcome of a call's reveal phase.
enum RevealOutcome {
  /// Not enough decisions in yet.
  pending,

  /// Both participants chose to reveal — unlock photo + show Match/Pass.
  mutual,

  /// At least one participant passed — no match.
  declined,
}

/// Resolved state of the post-reveal *decision* step.
enum MatchDecisionOutcome {
  /// Either side hasn't tapped Match/Pass yet (and nobody passed).
  awaitingPeer,

  /// Both peers tapped Match → create the permanent match + chat.
  mutualMatch,

  /// One side tapped Pass → no match.
  passed,
}

/// Backs the post-call reveal: records each user's photo-reveal decision
/// and post-reveal match decision in `public.reveals`, and (when both
/// pick Match) writes the permanent `public.matches` row.
class RevealRepository {
  RevealRepository(this._client);

  final SupabaseClient _client;
  static const _log = AppLogger('Reveal');

  /// Records (or updates) the current user's photo-reveal decision.
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

  /// Records (or updates) the current user's match-decision (`match` /
  /// `pass`) on a call where the reveal already mutualised.
  ///
  /// The match row + conversation are NOT created here — the caller waits
  /// for the realtime stream to confirm the *peer's* decision too (see
  /// [decisionOutcomeFor]). This is the product invariant: no match, no
  /// chat, until both users explicitly choose.
  Future<void> submitDecision({
    required String callId,
    required String userId,
    required String decision,
  }) async {
    assert(
      decision == 'match' || decision == 'pass',
      'decision must be "match" or "pass" (got "$decision")',
    );
    _log.info(
      'submitDecision call=$callId user=$userId decision=$decision',
    );
    await _client.from('reveals').upsert(
      {
        'call_id': callId,
        'user_id': userId,
        // Keep revealed=true so the table CHECK / outcomeFor still
        // resolve to "mutual reveal" — only `decision` changes here.
        'revealed': true,
        'decision': decision,
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

  /// Resolves the *photo-reveal* outcome given the reveal rows and the
  /// two expected participant ids.
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

  /// Resolves the *match decision* outcome (the second mutual step,
  /// after the photo reveal). Returns:
  ///   * [MatchDecisionOutcome.awaitingPeer] when at least one side is
  ///     still 'pending' and nobody has passed,
  ///   * [MatchDecisionOutcome.mutualMatch] when both sides decided
  ///     'match',
  ///   * [MatchDecisionOutcome.passed] as soon as either side decided
  ///     'pass'.
  MatchDecisionOutcome decisionOutcomeFor(
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
    final mineDecision = mine?.decision ?? 'pending';
    final theirsDecision = theirs?.decision ?? 'pending';
    if (mineDecision == 'pass' || theirsDecision == 'pass') {
      return MatchDecisionOutcome.passed;
    }
    if (mineDecision == 'match' && theirsDecision == 'match') {
      return MatchDecisionOutcome.mutualMatch;
    }
    return MatchDecisionOutcome.awaitingPeer;
  }

  /// Creates the permanent match row. Idempotent: the table's
  /// UNIQUE(user_a_id, user_b_id) + ordered-pair CHECK mean a second
  /// caller (the peer reaching `mutualMatch` at the same time) upserts
  /// the same row instead of duplicating it.
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
