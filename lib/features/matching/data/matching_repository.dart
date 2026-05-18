import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

import '../../../core/services/supabase_service.dart';
import '../../../core/utils/logger.dart';
import '../../profile_setup/data/profile_repository.dart';
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

/// Async source for real candidates. When wired (Supabase mode) it returns
/// the cross-user pool from the profile repository; null means "synthetic
/// only" — the historical demo behaviour.
typedef CandidateFetcher = Future<List<UserProfile>> Function(UserProfile self);

/// Pulls a candidate from the wired source (real Supabase pool when
/// available, synthetic factory otherwise), scores it via [MatchingService],
/// and packages the trio into an [ActiveMatch].
class MockMatchingRepository implements MatchingRepository {
  MockMatchingRepository(
    this._service, {
    MockCandidateFactory? factory,
    CandidateFetcher? candidateFetcher,
  })  : _factory = factory ?? MockCandidateFactory(),
        _candidateFetcher = candidateFetcher;

  final MatchingService _service;
  final MockCandidateFactory _factory;
  final CandidateFetcher? _candidateFetcher;
  static const _log = AppLogger('MockMatching');

  // Tries a few times in case the random draw produces a candidate that
  // would fail the hard gates (rare but possible).
  static const _maxAttempts = 5;

  @override
  Future<ActiveMatch?> findCandidate(UserProfile self) async {
    await Future<void>.delayed(const Duration(milliseconds: 350));

    // Prefer a real candidate from Supabase: rank every fetched profile,
    // return the best scoring one above the hard gates. If no real profile
    // matches, fall through to the synthetic factory so the flow keeps
    // working without real peers in the database.
    if (_candidateFetcher != null) {
      try {
        final reals = await _candidateFetcher(self);
        _log.info(
          'findCandidate: ${reals.length} real candidates from source',
        );
        ActiveMatch? best;
        int bestScore = -1;
        int rejected = 0;
        for (final c in reals) {
          final distanceKm = _factory.distanceFor(self);
          final score =
              _service.calculateCompatibility(self, c, distanceKm: distanceKm);
          if (score == null) {
            rejected++;
            continue;
          }
          if (score.percentage > bestScore) {
            bestScore = score.percentage;
            best = ActiveMatch(
              candidate: c,
              distanceKm: distanceKm,
              score: score,
            );
          }
        }
        _log.info(
          'findCandidate: rejected=$rejected '
          'bestScore=${best?.score.percentage ?? '—'}',
        );
        if (best != null) return best;
      } catch (e, st) {
        _log.error('candidate fetcher failed; falling back to synthetic', e, st);
      }
    }

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
  final service = ref.watch(matchingServiceProvider);
  final supabaseUp = ref.watch(supabaseAvailableProvider);
  if (!supabaseUp) {
    return MockMatchingRepository(service);
  }
  // Supabase available: rank real users (via ProfileRepository) instead of
  // synthesizing a candidate. Falls back to synthetic if the query fails or
  // returns no compatible profiles.
  final profiles = ref.watch(profileRepositoryProvider);
  return MockMatchingRepository(
    service,
    candidateFetcher: (self) =>
        profiles.fetchPotentialCandidates(selfUserId: self.userId),
  );
});
