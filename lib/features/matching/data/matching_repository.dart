import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

import '../../../core/utils/logger.dart';
import '../../profile_setup/domain/user_profile.dart';
import '../domain/active_match.dart';
import 'matching_service.dart';
import 'mock_candidate_factory.dart';

/// Looks up a candidate compatible with the current user and packages it as
/// an [ActiveMatch]. The interface is intentionally narrow so the real
/// Supabase realtime version can drop in without UI changes.
abstract class MatchingRepository {
  /// Finds a candidate respecting [self]'s reciprocal criteria. Returns
  /// `null` if no compatible profile is currently available.
  Future<ActiveMatch?> findCandidate(UserProfile self);

  /// Records the final post-call decision so the backend can build the match
  /// table (or, in the mock, just log it).
  Future<void> recordDecision({
    required UserProfile self,
    required UserProfile candidate,
    required bool wantsMatch,
  });
}

// ---------------------------------------------------------------------------
// Mock — generates a deterministic-ish candidate that passes the hard gates
// ---------------------------------------------------------------------------

/// Pulls a candidate from the shared [MockCandidateFactory], scores it via
/// [MatchingService], and packages the trio into an [ActiveMatch].
class MockMatchingRepository implements MatchingRepository {
  MockMatchingRepository(this._service, [MockCandidateFactory? factory])
      : _factory = factory ?? MockCandidateFactory();

  final MatchingService _service;
  final MockCandidateFactory _factory;
  static const _log = AppLogger('MockMatching');

  // Tries a few times in case the random draw produces a candidate that
  // would fail the hard gates (rare but possible).
  static const _maxAttempts = 5;

  @override
  Future<ActiveMatch?> findCandidate(UserProfile self) async {
    await Future<void>.delayed(const Duration(milliseconds: 350));

    for (var attempt = 0; attempt < _maxAttempts; attempt++) {
      final candidate = _factory.build(self);
      if (candidate == null) return null;
      final distanceKm = _factory.distanceFor(self);
      final score = _service.calculateCompatibility(
        self,
        candidate,
        distanceKm: distanceKm,
      );
      if (score != null) {
        return ActiveMatch(
          candidate: candidate,
          distanceKm: distanceKm,
          score: score,
        );
      }
      _log.warn('mock candidate failed hard gates (attempt $attempt)');
    }
    return null;
  }

  @override
  Future<void> recordDecision({
    required UserProfile self,
    required UserProfile candidate,
    required bool wantsMatch,
  }) async {
    _log.info(
      'decision: ${self.userId} → ${candidate.userId} '
      '(${wantsMatch ? 'match' : 'pass'})',
    );
  }
}

// ---------------------------------------------------------------------------
// Supabase — stub kept honest with an [UnimplementedError]
// ---------------------------------------------------------------------------

class SupabaseMatchingRepository implements MatchingRepository {
  SupabaseMatchingRepository(this._client);

  // ignore: unused_field
  final sb.SupabaseClient _client;

  @override
  Future<ActiveMatch?> findCandidate(UserProfile self) {
    // TODO(datenow): query candidates via a Supabase RPC / materialized
    // view that already filters by reciprocity, then compute the score
    // client-side using [MatchingService].
    throw UnimplementedError('SupabaseMatchingRepository.findCandidate');
  }

  @override
  Future<void> recordDecision({
    required UserProfile self,
    required UserProfile candidate,
    required bool wantsMatch,
  }) {
    throw UnimplementedError('SupabaseMatchingRepository.recordDecision');
  }
}

// ---------------------------------------------------------------------------
// Providers
// ---------------------------------------------------------------------------

final matchingServiceProvider =
    Provider<MatchingService>((_) => const MatchingService());

final matchingRepositoryProvider = Provider<MatchingRepository>((ref) {
  // TODO(datenow): the Supabase matching backend (a Postgres RPC that
  // returns reciprocal-compatible profiles) hasn't been implemented yet.
  // Use the synthetic candidate factory even when Supabase is configured
  // so the live-match flow stays demoable end-to-end.
  return MockMatchingRepository(ref.watch(matchingServiceProvider));
});
