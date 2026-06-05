import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

import '../../../core/services/supabase_service.dart';
import '../../../core/utils/logger.dart';
import '../../matching/data/mock_candidate_factory.dart';
import '../../matching/domain/match_score.dart';
import '../../profile_setup/data/profile_repository.dart';
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

/// Async source for real candidates — implemented by `ProfileRepository`
/// against Supabase, swappable in tests, and `null` by default so the
/// existing mock-only behaviour is preserved.
typedef CandidateSource = Future<List<UserProfile>> Function(UserProfile self);

/// Source for the **persisted** Discover "Confirmed matches" surface.
///
/// When provided, [MockDiscoverRepository.watchMatches] delegates to this
/// function instead of reading from its RAM map — so a confirmed match
/// shows up on **both** participants' phones (the row is in the `matches`
/// table, RLS authorises both participants). When `null`, the legacy
/// in-memory path is kept untouched (tests, no-Supabase mode).
typedef MutualMatchesSource = Stream<List<MutualMatch>> Function(String userId);

/// Persistent "already dated" history: every peer the user has ever launched a
/// call with (from the `calls` table). A launched date consumes the
/// suggestion FOREVER — even across a kill/restart where the RAM status is
/// lost — so the pair is never re-proposed. Null keeps the legacy RAM-only
/// behaviour (tests / no-Supabase mode).
typedef CalledPeerIdsSource = Future<Set<String>> Function(String selfUserId);

class MockDiscoverRepository implements DiscoverRepository {
  MockDiscoverRepository(
    this._service, {
    MockCandidateFactory? factory,
    CandidateSource? candidateSource,
    MutualMatchesSource? mutualMatchesSource,
    CalledPeerIdsSource? calledPeerIds,
  })  : _factory = factory ?? MockCandidateFactory(),
        _candidateSource = candidateSource,
        _mutualMatchesSource = mutualMatchesSource,
        _calledPeerIds = calledPeerIds;

  final WeeklySuggestionsService _service;
  final MockCandidateFactory _factory;
  final CandidateSource? _candidateSource;
  final MutualMatchesSource? _mutualMatchesSource;
  final CalledPeerIdsSource? _calledPeerIds;
  static const _log = AppLogger('MockDiscover');

  // How many synthetic candidates we generate when no real source is wired.
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
    // Week boundary is UTC-anchored (see WeeklySuggestionsService docs).
    // .toUtc() explicit here so the intent is obvious at the call site.
    final weekStart = WeeklySuggestionsService.startOfWeek(
      DateTime.now().toUtc(),
    );
    final existing = _suggestionsByUser[self.userId] ?? const [];
    final currentWeek = existing
        .where((s) =>
            s.weekStartDate == weekStart &&
            s.status != SuggestionStatus.dismissed)
        .toList();

    if (currentWeek.length >= WeeklySuggestionsService.weeklySlots) {
      return;
    }

    // Audit: dump the preferences the matcher will use so any "why doesn't
    // this profile match my filters?" question can be answered from logs.
    _log.info(
      'prefs self=${self.userId} gender=${self.gender?.name} '
      'orientation=${self.orientation?.name} age=${self.age} '
      'seekingGenders=${self.seekingGenders.map((g) => g.name).toList()} '
      'seekingAge=${self.seekingAgeMin}-${self.seekingAgeMax} '
      'maxDistance=${self.maxDistanceKm}km '
      'intentions=${self.intentions.length} interests=${self.interests.length} '
      'availability=${self.availability?.name}',
    );

    // Build the exclusion set: anyone the user has already seen in any
    // prior week (dismissed, call-started, matched) plus everyone they're
    // already in a mutual match with. selectFor receives this and skips
    // those candidates before scoring — never re-propose.
    final priorSuggestedIds =
        existing.map((s) => s.suggestedUserId).toSet();
    final mutualMatchIds = (_matchesByUser[self.userId] ?? const <MutualMatch>[])
        .map((m) => m.candidate.userId)
        .toSet();
    // Persistent "already dated" history (survives kill/restart): every peer
    // the user has launched a call with. A launched date consumes the
    // suggestion forever, so the pair is never re-proposed even after the RAM
    // status is gone. Best-effort — a failure just falls back to the RAM
    // exclusions above.
    final calledPeerIds =
        _calledPeerIds != null ? await _calledPeerIds(self.userId) : const <String>{};
    final excludedUserIds = {
      ...priorSuggestedIds,
      ...mutualMatchIds,
      ...calledPeerIds,
    };
    _log.info(
      'exclusions — suggested=${priorSuggestedIds.length} '
      'matched=${mutualMatchIds.length} called=${calledPeerIds.length}',
    );

    // Build the pool. When a real `CandidateSource` is wired (Supabase mode)
    // we ask it for every other completed profile; otherwise we fall back to
    // the synthetic factory so the demo path keeps working.
    final pool = <({UserProfile candidate, int distanceKm})>[];
    if (_candidateSource != null) {
      try {
        final reals = await _candidateSource(self);
        _log.info('pool: ${reals.length} real candidates from source');
        for (final c in reals) {
          // No geo backend yet — synthesise a plausible distance the same
          // way the factory does so the existing distance score keeps
          // weighting cross-user pairs.
          pool.add((
            candidate: c,
            distanceKm: _factory.distanceFor(self),
          ));
        }
      } catch (e, st) {
        _log.error('candidate source failed; falling back to synthetic', e, st);
      }
    }
    if (pool.isEmpty) {
      _log.info('using synthetic candidate factory (no real pool)');
      for (var i = 0; i < _poolSize; i++) {
        final candidate = _factory.build(self);
        if (candidate == null) {
          _log.warn('cannot build candidate — self profile is incomplete');
          return;
        }
        pool.add((
          candidate: candidate,
          distanceKm: _factory.distanceFor(self),
        ));
      }
    }

    final selected = _service.selectFor(
      self: self,
      pool: pool,
      excludedUserIds: excludedUserIds,
    );
    final missing =
        WeeklySuggestionsService.weeklySlots - currentWeek.length;
    final fresh = <WeeklySuggestion>[];
    // createdAt is stored / serialised — keep it UTC so it matches
    // the DB's TIMESTAMPTZ convention and renders consistently.
    final now = DateTime.now().toUtc();
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
      '(week of ${weekStart.toIso8601String()}, '
      'excluded ${excludedUserIds.length} historical ids)',
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
  Stream<List<MutualMatch>> watchMatches(String userId) {
    // When a Supabase-backed source is injected we read straight from the
    // `matches` table — that's the only way phone B can see the row that
    // phone A's reveal-repo upserted in DB. The RAM map is kept as the
    // fallback for tests and the no-Supabase mode.
    final supa = _mutualMatchesSource;
    if (supa != null) return supa(userId);
    return _ramWatchMatches(userId);
  }

  Stream<List<MutualMatch>> _ramWatchMatches(String userId) async* {
    yield _matchesByUser[userId] ?? const <MutualMatch>[];
    yield* _matchStream(userId).stream;
  }

  @override
  Future<void> recordMutualMatch({
    required UserProfile self,
    required UserProfile candidate,
    required MatchScore score,
  }) async {
    // With the Supabase source active, persistence is already done upstream
    // by `revealRepository.createMatch` (it upserts into `matches` from
    // post_call_screen for BOTH participants). Writing into the RAM map
    // would create a phantom row that nobody reads.
    if (_mutualMatchesSource != null) {
      _log.info(
        'recordMutualMatch no-op — Supabase source active; '
        'pair=${self.userId}↔${candidate.userId}',
      );
      return;
    }
    // matchedAt is stored / serialised — keep it UTC to match the
    // DB's TIMESTAMPTZ convention.
    final now = DateTime.now().toUtc();
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
// Supabase-backed "Confirmed matches" — reads the `matches` table directly
// (RLS authorises both participants), then hydrates each row with the peer's
// UserProfile via the existing ProfileRepository. Plugged into
// [MockDiscoverRepository] as a [MutualMatchesSource].
//
// We intentionally subscribe to the matches Realtime stream WITHOUT a client
// filter — RLS already constrains the rows to the calling user, and emissions
// trigger a hydrated re-fetch through `_fetch` (peer profiles aren't reachable
// from a single PostgREST embed because UserProfile spans profiles +
// user_preferences + user_photos).
// ---------------------------------------------------------------------------

class _SupabaseMutualMatchesSource {
  _SupabaseMutualMatchesSource({
    required sb.SupabaseClient client,
    required ProfileRepository profiles,
  })  : _client = client,
        _profiles = profiles;

  final sb.SupabaseClient _client;
  final ProfileRepository _profiles;
  static const _log = AppLogger('SupaMatches');
  static const _table = 'matches';

  Stream<List<MutualMatch>> watch(String userId) {
    // Each Realtime emission (initial snapshot + every change) triggers a
    // fresh hydrated fetch. Cheap: typical "Matchs effectués" cardinality
    // is single-digit per user.
    return _client
        .from(_table)
        .stream(primaryKey: ['id'])
        .asyncMap((_) => _fetch(userId));
  }

  Future<List<MutualMatch>> _fetch(String userId) async {
    try {
      final rows = await _client
          .from(_table)
          .select()
          .or('user_a_id.eq.$userId,user_b_id.eq.$userId')
          .order('matched_at', ascending: false);
      // Hydrate peers in parallel — N+1 is fine at this cardinality.
      final futures = rows.cast<Map<String, dynamic>>().map(
            (row) => _hydrate(row, userId),
          );
      final hydrated = await Future.wait(futures);
      return hydrated.whereType<MutualMatch>().toList(growable: false);
    } catch (e, st) {
      _log.error('fetch failed for $userId', e, st);
      return const <MutualMatch>[];
    }
  }

  Future<MutualMatch?> _hydrate(
    Map<String, dynamic> row,
    String userId,
  ) async {
    final aId = row['user_a_id'] as String;
    final bId = row['user_b_id'] as String;
    final peerId = aId == userId ? bId : aId;
    final peer = await _profiles.getProfile(peerId);
    if (peer == null) {
      _log.warn('peer profile $peerId missing — skipping match row ${row['id']}');
      return null;
    }
    return MutualMatch(
      id: row['id'] as String,
      userId: userId,
      candidate: peer,
      compatibilityScore: (row['compatibility_score'] as num?)?.toInt() ?? 0,
      matchedAt: DateTime.parse(row['matched_at'] as String).toUtc(),
      status: _statusFromWire(row['status'] as String?),
    );
  }

  /// `matches.status` is one of `'new' | 'conversation_open' | 'archived'`
  /// (cf. `20260513120000_initial_schema.sql`). The 'archived' wire value
  /// folds onto `newMatch` for now — Discover's UI doesn't distinguish it.
  MatchStatus _statusFromWire(String? wire) => switch (wire) {
        'conversation_open' => MatchStatus.conversationOpen,
        _ => MatchStatus.newMatch,
      };
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
  final service = ref.watch(weeklySuggestionsServiceProvider);
  final supabaseUp = ref.watch(supabaseAvailableProvider);
  if (!supabaseUp) {
    return MockDiscoverRepository(service);
  }
  // Supabase is configured:
  //   • candidate pool = real Supabase profiles,
  //   • "Confirmed matches" = the `matches` table directly, so phone B
  //     sees the row phone A's reveal repo upserted (and vice versa).
  // Weekly-suggestion cards stay in RAM for now — out of scope.
  final profiles = ref.watch(profileRepositoryProvider);
  final client = ref.watch(supabaseClientProvider);
  final supaMatches = _SupabaseMutualMatchesSource(
    client: client,
    profiles: profiles,
  );
  return MockDiscoverRepository(
    service,
    candidateSource: (self) =>
        profiles.fetchPotentialCandidates(selfUserId: self.userId),
    mutualMatchesSource: supaMatches.watch,
    calledPeerIds: (selfUserId) => _fetchCalledPeerIds(client, selfUserId),
  );
});

/// Every peer the user has ever launched (or received) a live date with, read
/// from the persistent `calls` table (RLS exposes rows where the caller is a
/// participant). Used to exclude already-dated pairs from new weekly
/// suggestions. Best-effort — returns empty on any error so suggestion
/// generation never breaks.
Future<Set<String>> _fetchCalledPeerIds(
  sb.SupabaseClient client,
  String selfUserId,
) async {
  const log = AppLogger('DiscoverCalls');
  try {
    final rows = await client
        .from('calls')
        .select('caller_id, callee_id')
        .or('caller_id.eq.$selfUserId,callee_id.eq.$selfUserId');
    final ids = <String>{};
    for (final row in rows.cast<Map<String, dynamic>>()) {
      final caller = row['caller_id'] as String?;
      final callee = row['callee_id'] as String?;
      if (caller != null && caller != selfUserId) ids.add(caller);
      if (callee != null && callee != selfUserId) ids.add(callee);
    }
    return ids;
  } catch (e, st) {
    log.error('fetchCalledPeerIds failed for $selfUserId', e, st);
    return const <String>{};
  }
}
