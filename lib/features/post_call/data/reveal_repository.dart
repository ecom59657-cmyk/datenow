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

/// Single source of truth for the post-call screen state, computed
/// purely from the live `reveals` rows. The post-call screen treats
/// this enum as authoritative: user taps only write to Supabase,
/// realtime emits the new rows, and the listener recomputes the
/// stage via [PostCallStage.fromRows].
///
/// Mapping (mine.revealed / theirs.revealed / mine.decision / theirs.decision):
///   pending           — neither row exists yet (call just ended)
///   selfDecideReveal  — neither row decided, or only self knows of the call
///   waitingForPeerReveal — mine.revealed=true, theirs not yet revealed
///   peerPassedAtReveal — theirs.revealed=false (terminal: noMatch)
///   selfPassedAtReveal — mine.revealed=false (terminal: passed)
///   mutual            — both revealed=true, both decision='pending'
///   awaitingPeerMatch — mine.decision='match', theirs='pending'
///   peerWantsMatch    — mine='pending', theirs='match'  (functionally
///                       same UI as mutual, but logged separately)
///   matched           — both decision='match'
///   selfPassed        — mine.decision='pass'
///   peerPassed        — theirs.decision='pass', mine in {pending, match}
enum PostCallStage {
  pending,
  selfDecideReveal,
  waitingForPeerReveal,
  selfPassedAtReveal,
  peerPassedAtReveal,
  mutual,
  awaitingPeerMatch,
  peerWantsMatch,
  matched,
  selfPassed,
  peerPassed;

  /// Pure mapping (self, peer) rows → stage. The caller must already
  /// know which row belongs to self / peer.
  static PostCallStage fromRows(
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
    if (mine == null && theirs == null) return PostCallStage.pending;

    // Photo-reveal phase
    if (mine == null) {
      // Peer acted first — we haven't written anything yet.
      return PostCallStage.selfDecideReveal;
    }
    if (mine.revealed == false) {
      // self pressed Passer at the reveal step
      return PostCallStage.selfPassedAtReveal;
    }
    // mine.revealed == true here
    if (theirs == null || (theirs.revealed != true && theirs.revealed != false)) {
      // theirs missing entirely → still waiting on peer to reveal
      return PostCallStage.waitingForPeerReveal;
    }
    if (theirs.revealed == false) {
      return PostCallStage.peerPassedAtReveal;
    }

    // Both revealed=true → decision phase
    final mineDec = mine.decision;
    final theirsDec = theirs.decision;

    if (mineDec == 'pass') return PostCallStage.selfPassed;
    if (theirsDec == 'pass') return PostCallStage.peerPassed;
    if (mineDec == 'match' && theirsDec == 'match') {
      return PostCallStage.matched;
    }
    if (mineDec == 'match') return PostCallStage.awaitingPeerMatch;
    if (theirsDec == 'match') return PostCallStage.peerWantsMatch;
    return PostCallStage.mutual; // both pending
  }

  /// True once the stage represents a final, non-recoverable outcome.
  /// The listener uses this to stop re-applying transitions and the
  /// dispatch logic uses it to gate side-effects (create match,
  /// cancel timeouts…).
  bool get isTerminal => switch (this) {
        PostCallStage.matched => true,
        PostCallStage.selfPassed => true,
        PostCallStage.peerPassed => true,
        PostCallStage.selfPassedAtReveal => true,
        PostCallStage.peerPassedAtReveal => true,
        _ => false,
      };
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

  /// Creates the permanent match row.
  ///
  /// V1 Hardening (Pass 5 M1) :
  /// Previously this method did a direct `.from('matches').upsert(...)`
  /// via PostgREST. The RLS policy `matches_all_participant` was FOR
  /// ALL, so the only server-side check was "caller participates" —
  /// a tampered client could forge a match row WITHOUT both peers
  /// actually having a `reveals.decision='match'` on the same call.
  ///
  /// Now we call the SECURITY DEFINER RPC `create_match_if_mutual`.
  /// The RPC re-checks server-side that:
  ///   * the caller is one of the call's participants ;
  ///   * BOTH participants have a `decision='match'` reveal on this
  ///     `call_id` (no spoofing the peer's vote).
  /// On its own UNIQUE(user_a_id, user_b_id), the function is
  /// idempotent : a concurrent second call (the peer reaching
  /// `mutualMatch` at the same instant) updates the existing row
  /// instead of duplicating it.
  ///
  /// `userA`/`userB` params are kept for the caller-side log message
  /// but the RPC resolves the canonical pair from the call_id, so
  /// the caller cannot lie about who participates.
  Future<void> createMatch({
    required String callId,
    required String userA,
    required String userB,
    required int compatibilityScore,
  }) async {
    final ordered = [userA, userB]..sort();
    _log.info(
      'createMatch — pair=${ordered.first}/${ordered.last} '
      'call=$callId score=$compatibilityScore (via RPC)',
    );
    await _client.rpc<dynamic>(
      'create_match_if_mutual',
      params: {
        'p_call_id': callId,
        'p_compatibility_score': compatibilityScore.clamp(0, 100),
      },
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
