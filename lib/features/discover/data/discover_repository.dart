import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

import '../../../core/utils/logger.dart';
import '../../matching/data/mock_candidate_factory.dart';
import '../../matching/domain/match_score.dart';
import '../../profile_setup/domain/user_profile.dart';
import '../domain/match_status.dart';
import '../domain/mutual_match.dart';
import '../domain/suggestion_status.dart';
import '../domain/weekly_suggestion.dart';
import 'weekly_suggestions_service.dart';

/// Persists the user-facing Discover tab state: the weekly suggestions
/// batch + the list of confirmed mutual matches. Both surfaces are
/// reactive — UI subscribes via [watchSuggestions] / [watchMatches].
abstract class DiscoverRepository {
  Stream<List<WeeklySuggestion>> watchSuggestions(String userId);

  /// Idempotent: if a non-dismissed batch already exists for the current
  /// week, this is a no-op. Otherwise it generates fresh suggestions for
  /// [self] up to [WeeklySuggestionsService.weeklySlots].
  Future<void> ensureWeeklyBatch(UserProfile self);

  Future<void> dismissSuggestion(String suggestionId);
  Future<void> markSuggestionCallStarted(String suggestionId);
  Future<void> markSuggestionMatched(String suggestionId);

  Stream<List<MutualMatch>> watchMatches(String userId);

  Future<void> recordMutualMatch({
    required UserProfile self,
    required UserProfile candidate,
    required MatchScore score,
  });
}

// ---------------------------------------------------------------------------
// Mock — in-memory store keyed by userId. Resets on app restart, which is
// fine for the demo; suggestions auto-regenerate on first open.
// ---------------------------------------------------------------------------

class MockDiscoverRepository implements DiscoverRepository {
  MockDiscoverRepository(this._service, [MockCandidateFactory? factory])
      : _factory = factory ?? MockCandidateFactory();

  final WeeklySuggestionsService _service;
  final MockCandidateFactory _factory;
  static const _log = AppLogger('MockDiscover');

  // How many candidates we try before declaring a sparse week.
  static const _poolSize = 30;

  final Map<String, List<WeeklySuggestion>> _suggestionsByUser = {};
  final Map<String, StreamController<List<WeeklySuggestion>>>
      _suggestionStreams = {};

  final Map<String, List<MutualMatch>> _matchesByUser = {};
  final Map<String, StreamController<List<MutualMatch>>> _matchStreams = {};

  StreamController<List<WeeklySuggestion>> _suggStream(String userId) {
    return _suggestionStreams.putIfAbsent(
      userId,
      () => StreamController<List<WeeklySuggestion>>.broadcast(),
    );
  }

  StreamController<List<MutualMatch>> _matchStream(String userId) {
    return _matchStreams.putIfAbsent(
      userId,
      () => StreamController<List<MutualMatch>>.broadcast(),
    );
  }

  List<WeeklySuggestion> _visibleSuggestions(String userId) {
    final all = _suggestionsByUser[userId] ?? const <WeeklySuggestion>[];
    return all
        .where((s) => s.status != SuggestionStatus.dismissed)
        .toList(growable: false);
  }

  @override
  Stream<List<WeeklySuggestion>> watchSuggestions(String userId) async* {
    yield _visibleSuggestions(userId);
    yield* _suggStream(userId).stream;
  }

  @override
  Future<void> ensureWeeklyBatch(UserProfile self) async {
    final weekStart = WeeklySuggestionsService.startOfWeek(DateTime.now());
    final existing = _suggestionsByUser[self.userId] ?? const [];
    final currentWeek = existing
        .where((s) =>
            s.weekStartDate == weekStart &&
            s.status != SuggestionStatus.dismissed)
        .toList();

    if (currentWeek.length >= WeeklySuggestionsService.weeklySlots) {
      return;
    }

    // Build a pool of synthetic candidates large enough to find a few
    // scoring at or above the floor.
    final pool = <({UserProfile candidate, int distanceKm})>[];
    for (var i = 0; i < _poolSize; i++) {
      final candidate = _factory.build(self);
      if (candidate == null) {
        _log.warn('cannot build candidate — self profile is incomplete');
        return;
      }
      pool.add((candidate: candidate, distanceKm: _factory.distanceFor(self)));
    }

    final selected = _service.selectFor(self: self, pool: pool);
    final missing =
        WeeklySuggestionsService.weeklySlots - currentWeek.length;
    final fresh = <WeeklySuggestion>[];
    final now = DateTime.now();
    for (final ranked in selected.take(missing)) {
      fresh.add(
        WeeklySuggestion(
          id: 'sugg-${now.microsecondsSinceEpoch}-${fresh.length}',
          userId: self.userId,
          suggestedUserId: ranked.candidate.userId,
          compatibilityScore: ranked.score.percentage,
          weekStartDate: weekStart,
          status: SuggestionStatus.pending,
          createdAt: now,
          candidate: ranked.candidate,
          distanceKm: ranked.distanceKm,
        ),
      );
    }

    _suggestionsByUser[self.userId] = [...existing, ...fresh];
    _suggStream(self.userId).add(_visibleSuggestions(self.userId));
    _log.info(
      'generated ${fresh.length} suggestions for ${self.userId} '
      '(week of ${weekStart.toIso8601String()})',
    );
  }

  WeeklySuggestion? _findSuggestion(String id) {
    for (final list in _suggestionsByUser.values) {
      for (final s in list) {
        if (s.id == id) return s;
      }
    }
    return null;
  }

  void _updateSuggestion(String id, WeeklySuggestion Function(WeeklySuggestion) f) {
    final current = _findSuggestion(id);
    if (current == null) return;
    final updated = f(current);
    final list = _suggestionsByUser[current.userId];
    if (list == null) return;
    final idx = list.indexWhere((s) => s.id == id);
    if (idx < 0) return;
    final next = [...list]..[idx] = updated;
    _suggestionsByUser[current.userId] = next;
    _suggStream(current.userId).add(_visibleSuggestions(current.userId));
  }

  @override
  Future<void> dismissSuggestion(String suggestionId) async {
    _updateSuggestion(
      suggestionId,
      (s) => s.copyWith(status: SuggestionStatus.dismissed),
    );
  }

  @override
  Future<void> markSuggestionCallStarted(String suggestionId) async {
    _updateSuggestion(
      suggestionId,
      (s) => s.copyWith(status: SuggestionStatus.callStarted),
    );
  }

  @override
  Future<void> markSuggestionMatched(String suggestionId) async {
    _updateSuggestion(
      suggestionId,
      (s) => s.copyWith(status: SuggestionStatus.matched),
    );
  }

  @override
  Stream<List<MutualMatch>> watchMatches(String userId) async* {
    yield _matchesByUser[userId] ?? const <MutualMatch>[];
    yield* _matchStream(userId).stream;
  }

  @override
  Future<void> recordMutualMatch({
    required UserProfile self,
    required UserProfile candidate,
    required MatchScore score,
  }) async {
    final now = DateTime.now();
    final mm = MutualMatch(
      id: 'mm-${now.microsecondsSinceEpoch}',
      userId: self.userId,
      candidate: candidate,
      compatibilityScore: score.percentage,
      matchedAt: now,
      status: MatchStatus.newMatch,
    );
    final list = [..._matchesByUser[self.userId] ?? const <MutualMatch>[], mm];
    _matchesByUser[self.userId] = list;
    _matchStream(self.userId).add(list);
    _log.info('mutual match recorded for ${self.userId} ↔ ${candidate.userId}');
  }
}

// ---------------------------------------------------------------------------
// Supabase — stub kept honest with [UnimplementedError]
// ---------------------------------------------------------------------------

class SupabaseDiscoverRepository implements DiscoverRepository {
  SupabaseDiscoverRepository(this._client);

  // ignore: unused_field
  final sb.SupabaseClient _client;

  @override
  Stream<List<WeeklySuggestion>> watchSuggestions(String userId) {
    // TODO(datenow): subscribe to a `suggestions` table filtered by
    // `user_id = current_user() AND week_start_date = startOfWeek()`.
    throw UnimplementedError('SupabaseDiscoverRepository.watchSuggestions');
  }

  @override
  Future<void> ensureWeeklyBatch(UserProfile self) {
    // TODO(datenow): call a Postgres function `generate_weekly_suggestions`
    // that runs the reciprocal-compatibility query server-side.
    throw UnimplementedError('SupabaseDiscoverRepository.ensureWeeklyBatch');
  }

  @override
  Future<void> dismissSuggestion(String suggestionId) {
    throw UnimplementedError('SupabaseDiscoverRepository.dismissSuggestion');
  }

  @override
  Future<void> markSuggestionCallStarted(String suggestionId) {
    throw UnimplementedError(
      'SupabaseDiscoverRepository.markSuggestionCallStarted',
    );
  }

  @override
  Future<void> markSuggestionMatched(String suggestionId) {
    throw UnimplementedError(
      'SupabaseDiscoverRepository.markSuggestionMatched',
    );
  }

  @override
  Stream<List<MutualMatch>> watchMatches(String userId) {
    throw UnimplementedError('SupabaseDiscoverRepository.watchMatches');
  }

  @override
  Future<void> recordMutualMatch({
    required UserProfile self,
    required UserProfile candidate,
    required MatchScore score,
  }) {
    throw UnimplementedError('SupabaseDiscoverRepository.recordMutualMatch');
  }
}

// ---------------------------------------------------------------------------
// Provider
// ---------------------------------------------------------------------------

final discoverRepositoryProvider = Provider<DiscoverRepository>((ref) {
  // TODO(datenow): the Supabase weekly-suggestions + mutual-matches
  // backend hasn't shipped yet (needs a CRON job + materialised view).
  // We use the in-memory mock even when Supabase is configured so the
  // Discover tab stays interactive instead of throwing.
  return MockDiscoverRepository(ref.watch(weeklySuggestionsServiceProvider));
});
