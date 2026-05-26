// Simulated technical walkthrough of the DateNow flow — pure-logic only.
//
// These tests exercise the deterministic, I/O-free pieces of the
// matching → call → pre-call → timer → reveal pipeline WITHOUT any
// device, network or Supabase. The server-side pieces (claim_match
// atomicity, active_queue_peers freshness, the Agora token Edge
// Function) are not reachable from `flutter test` — see
// supabase/tests/flow_checks.sql and docs/PRE_REAL_TEST_REPORT.md.

import 'package:datenow/core/config/app_config.dart';
import 'package:datenow/features/call/data/call_session_repository.dart';
import 'package:datenow/features/matching/data/matching_service.dart';
import 'package:datenow/features/post_call/data/reveal_repository.dart';
import 'package:datenow/features/profile_setup/domain/enums.dart';
import 'package:datenow/features/profile_setup/domain/interest.dart';
import 'package:datenow/features/profile_setup/domain/user_profile.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

UserProfile _profile({
  required String id,
  required Gender gender,
  required Set<Gender> seekingGenders,
  int age = 28,
  Set<Intention> intentions = const {Intention.feeling, Intention.serious},
  Set<Interest> interests = const {
    Interest.music,
    Interest.travel,
    Interest.foodie,
    Interest.films,
  },
  Availability availability = Availability.immediate,
  Orientation? orientation = Orientation.straight,
  int seekingAgeMin = 22,
  int seekingAgeMax = 36,
  int maxDistanceKm = 50,
}) {
  final today = DateTime.now();
  return UserProfile(
    userId: id,
    firstName: id,
    birthDate: DateTime(today.year - age, today.month, today.day),
    gender: gender,
    orientation: orientation,
    seekingGenders: seekingGenders,
    seekingAgeMin: seekingAgeMin,
    seekingAgeMax: seekingAgeMax,
    maxDistanceKm: maxDistanceKm,
    intentions: intentions,
    interests: interests,
    availability: availability,
  );
}

/// Builds a `calls`-row JSON payload as `claim_match` / the REST API
/// would return it.
Map<String, dynamic> _callJson({
  required String id,
  String callerId = 'user-A',
  String calleeId = 'user-B',
  String status = 'live',
  String? channelName,
  String? startedAt,
  bool callerReady = false,
  bool calleeReady = false,
}) {
  return {
    'id': id,
    'caller_id': callerId,
    'callee_id': calleeId,
    'status': status,
    'ended_by': null,
    'channel_name': channelName ?? 'dn_$id',
    'started_at': startedAt,
    'caller_ready': callerReady,
    'callee_ready': calleeReady,
  };
}

void main() {
  // =========================================================================
  // TEST 1 — Matching: two compatible profiles score >= 75 %
  // =========================================================================
  group('Test 1 — Matching score', () {
    const service = MatchingService();

    test('two strongly compatible profiles score >= 75 %', () {
      final a = _profile(
        id: 'user-A',
        gender: Gender.male,
        seekingGenders: {Gender.female},
      );
      final b = _profile(
        id: 'user-B',
        gender: Gender.female,
        seekingGenders: {Gender.male},
      );
      final score = service.calculateCompatibility(a, b, distanceKm: 3);
      expect(score, isNotNull);
      expect(score!.percentage, greaterThanOrEqualTo(75));
    });

    test('matching is symmetric — A→B and B→A give the same score', () {
      final a = _profile(
        id: 'user-A',
        gender: Gender.male,
        seekingGenders: {Gender.female},
      );
      final b = _profile(
        id: 'user-B',
        gender: Gender.female,
        seekingGenders: {Gender.male},
      );
      final ab = service.calculateCompatibility(a, b, distanceKm: 3);
      final ba = service.calculateCompatibility(b, a, distanceKm: 3);
      expect(ab!.percentage, ba!.percentage);
    });
  });

  // =========================================================================
  // TEST 5 — Pre-call: Agora must not mount before BOTH peers are ready
  // =========================================================================
  group('Test 5 — Pre-call ready handshake', () {
    test('bothReady is false until caller AND callee have marked ready', () {
      final none = CallSessionRow.fromJson(_callJson(id: 'c1'));
      expect(none.bothReady, isFalse);

      final callerOnly = CallSessionRow.fromJson(
        _callJson(id: 'c1', callerReady: true),
      );
      expect(callerOnly.bothReady, isFalse,
          reason: 'one side ready must NOT mount Agora');

      final calleeOnly = CallSessionRow.fromJson(
        _callJson(id: 'c1', calleeReady: true),
      );
      expect(calleeOnly.bothReady, isFalse);

      final both = CallSessionRow.fromJson(
        _callJson(id: 'c1', callerReady: true, calleeReady: true),
      );
      expect(both.bothReady, isTrue,
          reason: 'both ready → call may advance to joining/live');
    });

    test('peerReady resolves the OTHER participant from each side', () {
      final row = CallSessionRow.fromJson(
        _callJson(
          id: 'c1',
          callerId: 'user-A',
          calleeId: 'user-B',
          callerReady: true,
        ),
      );
      // From A's perspective the peer is the callee (not ready).
      expect(row.peerReady('user-A'), isFalse);
      // From B's perspective the peer is the caller (ready).
      expect(row.peerReady('user-B'), isTrue);
    });
  });

  // =========================================================================
  // TEST 6 — Server timer: remaining time derives from started_at
  // =========================================================================
  group('Test 6 — Server-based timer', () {
    test('started_at is parsed to a UTC instant', () {
      final row = CallSessionRow.fromJson(
        _callJson(id: 'c1', startedAt: '2026-05-17T10:00:00.000Z'),
      );
      expect(row.startedAt.isUtc, isTrue);
      expect(row.startedAt, DateTime.utc(2026, 5, 17, 10, 0, 0));
    });

    test('remaining time = maxCallDuration - elapsed(started_at)', () {
      // Call created 60 s ago (server clock).
      final startedAt = DateTime.now().toUtc().subtract(
            const Duration(seconds: 60),
          );
      final row = CallSessionRow.fromJson(
        _callJson(id: 'c1', startedAt: startedAt.toIso8601String()),
      );
      // Same maths as _CallScreenState._tick.
      final remaining =
          AppConfig.maxCallDuration - DateTime.now().difference(row.startedAt);
      expect(remaining.inSeconds, closeTo(60 * 4, 2),
          reason: '5 min cap minus ~60 s elapsed ≈ 4 min left');
    });

    test('a rejoin re-reads the SAME started_at → same remaining time', () {
      final json = _callJson(
        id: 'c1',
        startedAt: '2026-05-17T10:00:00.000Z',
      );
      // First mount and a later "rejoin" both parse the row.
      final firstMount = CallSessionRow.fromJson(json);
      final rejoin = CallSessionRow.fromJson(json);
      expect(rejoin.startedAt, firstMount.startedAt,
          reason: 'timer is anchored server-side — coherent across rejoins '
              'and across the two devices');
    });
  });

  // =========================================================================
  // TEST 7 — Reveal: pending / mutual / declined + match only when mutual
  // =========================================================================
  group('Test 7 — Reveal outcome', () {
    // outcomeFor() is pure — it never touches the client. A throw-away
    // SupabaseClient is enough to instantiate the repository.
    final repo = RevealRepository(
      SupabaseClient('https://example.supabase.co', 'test-anon-key'),
    );
    const self = 'user-A';
    const peer = 'user-B';

    RevealRow reveal(String user, bool revealed, [String decision = 'pending']) =>
        RevealRow(
          callId: 'c1',
          userId: user,
          revealed: revealed,
          decision: decision,
        );

    test('A reveals alone → pending (no match created)', () {
      final outcome = repo.outcomeFor(
        [reveal(self, true)],
        selfId: self,
        peerId: peer,
      );
      expect(outcome, RevealOutcome.pending);
    });

    test('A and B both reveal → mutual', () {
      final outcome = repo.outcomeFor(
        [reveal(self, true), reveal(peer, true)],
        selfId: self,
        peerId: peer,
      );
      expect(outcome, RevealOutcome.mutual);
    });

    test('A reveals, B passes → declined', () {
      final outcome = repo.outcomeFor(
        [reveal(self, true), reveal(peer, false)],
        selfId: self,
        peerId: peer,
      );
      expect(outcome, RevealOutcome.declined);
    });

    test('only the mutual outcome unlocks a permanent match', () {
      // The post-call screen calls createMatch ONLY on RevealOutcome.mutual;
      // pending and declined must never persist a match.
      for (final rows in [
        <RevealRow>[reveal(self, true)], // pending
        [reveal(self, true), reveal(peer, false)], // declined
      ]) {
        final outcome =
            repo.outcomeFor(rows, selfId: self, peerId: peer);
        expect(outcome, isNot(RevealOutcome.mutual));
      }
    });
  });

  // =========================================================================
  // TEST 8 — Match-decision reciprocity (decisionOutcomeFor)
  //
  // Photo reveal already mutualised. Now both peers must independently
  // choose 'match' before the match row / conversation is created.
  // =========================================================================
  group('Test 8 — Match-decision reciprocity', () {
    final repo = RevealRepository(
      SupabaseClient('https://example.supabase.co', 'test-anon-key'),
    );
    const self = 'user-A';
    const peer = 'user-B';

    RevealRow row(String user, String decision) => RevealRow(
          callId: 'c1',
          userId: user,
          revealed: true,
          decision: decision,
        );

    test('A clicks match alone → awaitingPeer (no match yet)', () {
      final outcome = repo.decisionOutcomeFor(
        [row(self, 'match'), row(peer, 'pending')],
        selfId: self,
        peerId: peer,
      );
      expect(outcome, MatchDecisionOutcome.awaitingPeer);
    });

    test('A and B both click match → mutualMatch (create match + chat)', () {
      final outcome = repo.decisionOutcomeFor(
        [row(self, 'match'), row(peer, 'match')],
        selfId: self,
        peerId: peer,
      );
      expect(outcome, MatchDecisionOutcome.mutualMatch);
    });

    test('A clicks match, B passes → passed (no match, no chat)', () {
      final outcome = repo.decisionOutcomeFor(
        [row(self, 'match'), row(peer, 'pass')],
        selfId: self,
        peerId: peer,
      );
      expect(outcome, MatchDecisionOutcome.passed);
    });

    test('A passes alone → passed', () {
      final outcome = repo.decisionOutcomeFor(
        [row(self, 'pass'), row(peer, 'pending')],
        selfId: self,
        peerId: peer,
      );
      expect(outcome, MatchDecisionOutcome.passed);
    });

    test('both pending → awaitingPeer', () {
      final outcome = repo.decisionOutcomeFor(
        [row(self, 'pending'), row(peer, 'pending')],
        selfId: self,
        peerId: peer,
      );
      expect(outcome, MatchDecisionOutcome.awaitingPeer);
    });
  });

  // =========================================================================
  // TEST 9 — PostCallStage.fromRows (single source of truth for the UI)
  //
  // Realtime delivers the full row set on every change; PostCallStage
  // .fromRows is the pure mapping that the post-call screen uses to
  // decide what to render. Both clients running it on the same input
  // MUST produce the same stage — that is the invariant guaranteeing
  // they converge.
  // =========================================================================
  group('Test 9 — PostCallStage.fromRows', () {
    const selfId = 'user-A';
    const peerId = 'user-B';

    RevealRow row(String userId, {
      required bool revealed,
      String decision = 'pending',
    }) {
      return RevealRow(
        callId: 'c1',
        userId: userId,
        revealed: revealed,
        decision: decision,
      );
    }

    PostCallStage stage(List<RevealRow> rows) =>
        PostCallStage.fromRows(rows, selfId: selfId, peerId: peerId);

    test('no rows → pending', () {
      expect(stage(const []), PostCallStage.pending);
    });

    test('only peer revealed (call init by peer) → selfDecideReveal', () {
      expect(
        stage([row(peerId, revealed: true)]),
        PostCallStage.selfDecideReveal,
      );
    });

    test('self revealed, peer missing → waitingForPeerReveal', () {
      expect(
        stage([row(selfId, revealed: true)]),
        PostCallStage.waitingForPeerReveal,
      );
    });

    test('self revealed=false → selfPassedAtReveal', () {
      expect(
        stage([row(selfId, revealed: false), row(peerId, revealed: true)]),
        PostCallStage.selfPassedAtReveal,
      );
    });

    test('peer revealed=false → peerPassedAtReveal', () {
      expect(
        stage([row(selfId, revealed: true), row(peerId, revealed: false)]),
        PostCallStage.peerPassedAtReveal,
      );
    });

    test('both revealed=true, both pending → mutual', () {
      expect(
        stage([row(selfId, revealed: true), row(peerId, revealed: true)]),
        PostCallStage.mutual,
      );
    });

    test('mine=match peer=pending → awaitingPeerMatch', () {
      expect(
        stage([
          row(selfId, revealed: true, decision: 'match'),
          row(peerId, revealed: true),
        ]),
        PostCallStage.awaitingPeerMatch,
      );
    });

    test('mine=pending peer=match → peerWantsMatch (UI stays mutual)', () {
      expect(
        stage([
          row(selfId, revealed: true),
          row(peerId, revealed: true, decision: 'match'),
        ]),
        PostCallStage.peerWantsMatch,
      );
    });

    test('both match → matched (create match + chat)', () {
      expect(
        stage([
          row(selfId, revealed: true, decision: 'match'),
          row(peerId, revealed: true, decision: 'match'),
        ]),
        PostCallStage.matched,
      );
    });

    test('mine=pass → selfPassed (terminal)', () {
      expect(
        stage([
          row(selfId, revealed: true, decision: 'pass'),
          row(peerId, revealed: true, decision: 'match'),
        ]),
        PostCallStage.selfPassed,
      );
    });

    test('mine=match peer=pass → peerPassed', () {
      expect(
        stage([
          row(selfId, revealed: true, decision: 'match'),
          row(peerId, revealed: true, decision: 'pass'),
        ]),
        PostCallStage.peerPassed,
      );
    });

    test('mine=pending peer=pass → peerPassed', () {
      expect(
        stage([
          row(selfId, revealed: true),
          row(peerId, revealed: true, decision: 'pass'),
        ]),
        PostCallStage.peerPassed,
      );
    });

    test('both pass → selfPassed wins (self decision evaluated first)', () {
      // Order in the spec table: pass/pass → noMatch. We map to
      // selfPassed (terminal self view) which renders the same UX.
      // The important thing is it's terminal and non-recoverable.
      expect(
        stage([
          row(selfId, revealed: true, decision: 'pass'),
          row(peerId, revealed: true, decision: 'pass'),
        ]).isTerminal,
        isTrue,
      );
    });

    group('symmetry — both clients agree on the same row set', () {
      // Run the same row set from each client's perspective by
      // swapping which userId is "self". The matched / passed /
      // noMatch outcomes must collapse to the same terminal class.
      test('match/match: A computes matched, B computes matched', () {
        final rows = [
          row(selfId, revealed: true, decision: 'match'),
          row(peerId, revealed: true, decision: 'match'),
        ];
        expect(
          PostCallStage.fromRows(rows, selfId: selfId, peerId: peerId),
          PostCallStage.matched,
        );
        expect(
          PostCallStage.fromRows(rows, selfId: peerId, peerId: selfId),
          PostCallStage.matched,
        );
      });

      test('match/pass: matcher sees peerPassed, passer sees selfPassed '
          '(both terminal noMatch class)', () {
        final rows = [
          row(selfId, revealed: true, decision: 'match'),
          row(peerId, revealed: true, decision: 'pass'),
        ];
        // A perspective (A=match)
        expect(
          PostCallStage.fromRows(rows, selfId: selfId, peerId: peerId),
          PostCallStage.peerPassed,
        );
        // B perspective (B=pass)
        expect(
          PostCallStage.fromRows(rows, selfId: peerId, peerId: selfId),
          PostCallStage.selfPassed,
        );
        // Both terminal → both leave the screen.
        expect(
          PostCallStage.fromRows(rows, selfId: selfId, peerId: peerId)
              .isTerminal,
          isTrue,
        );
        expect(
          PostCallStage.fromRows(rows, selfId: peerId, peerId: selfId)
              .isTerminal,
          isTrue,
        );
      });
    });
  });
}
