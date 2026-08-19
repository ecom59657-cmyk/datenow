import 'dart:async';

import 'package:flutter/foundation.dart';
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
// Supabase — weekly suggestions persisted in `public.weekly_suggestions`
// ---------------------------------------------------------------------------

/// Suggestions that survive a restart.
///
/// Until now the weekly batch lived in a `Map` in [MockDiscoverRepository]:
/// killing the app regenerated three brand-new people, and the "never
/// re-propose someone" rule only held for the lifetime of the process.
/// Rows now go to `public.weekly_suggestions`, whose RLS policy
/// (`suggestions_all_owner`) scopes every read and write to the owner.
///
/// Matches are NOT written here. `public.matches` is only ever created by
/// the `create_match_if_mutual` SECURITY DEFINER RPC — a deliberate
/// hardening (cf. `RevealRepository.createMatch`) that stops a tampered
/// client from forging a match without both peers having voted. This class
/// reads matches through [_SupabaseMutualMatchesSource], exactly as the
/// provider already did, and [recordMutualMatch] stays a no-op.
class SupabaseDiscoverRepository implements DiscoverRepository {
  SupabaseDiscoverRepository({
    required sb.SupabaseClient client,
    required WeeklySuggestionsService service,
    required ProfileRepository profiles,
    required MockCandidateFactory factory,
  })  : _client = client,
        _service = service,
        _profiles = profiles,
        _factory = factory,
        _matches = _SupabaseMutualMatchesSource(
          client: client,
          profiles: profiles,
        );

  final sb.SupabaseClient _client;
  final WeeklySuggestionsService _service;
  final ProfileRepository _profiles;

  /// Still needed for the distance the scorer weighs. There is no geo
  /// backend yet, so this is a synthetic value — see [_hydrate] for why it
  /// is never persisted nor shown.
  final MockCandidateFactory _factory;
  final _SupabaseMutualMatchesSource _matches;

  static const _log = AppLogger('SupaDiscover');
  static const _table = 'weekly_suggestions';

  /// `week_start_date` is a SQL DATE — send it as `YYYY-MM-DD`, never as a
  /// full ISO timestamp, or the UNIQUE(user, peer, week) constraint stops
  /// matching rows written by a client in another timezone.
  @visibleForTesting
  static String weekKey(DateTime weekStart) => _weekKey(weekStart);

  static String _weekKey(DateTime weekStart) =>
      weekStart.toUtc().toIso8601String().split('T').first;

  static DateTime _currentWeekStart() =>
      WeeklySuggestionsService.startOfWeek(DateTime.now().toUtc());

  // -------------------------------------------------------------------
  // Reads
  // -------------------------------------------------------------------

  @override
  Stream<List<WeeklySuggestion>> watchSuggestions(String userId) {
    // Realtime gives us the row set; each emission re-hydrates, because
    // `weekly_suggestions` stores only the peer's id — the card needs the
    // whole profile. Cardinality is 3, so the N+1 is irrelevant.
    return _client
        .from(_table)
        .stream(primaryKey: ['id'])
        .eq('user_id', userId)
        .asyncMap((rows) => _hydrateAll(rows, userId));
  }

  Future<List<WeeklySuggestion>> _hydrateAll(
    List<Map<String, dynamic>> rows,
    String userId,
  ) async {
    final week = _weekKey(_currentWeekStart());
    final visible = rows.where(
      (r) => r['status'] != 'dismissed' && r['week_start_date'] == week,
    );
    final hydrated = await Future.wait(visible.map(_hydrate));
    return hydrated.whereType<WeeklySuggestion>().toList(growable: false);
  }

  Future<WeeklySuggestion?> _hydrate(Map<String, dynamic> row) async {
    final peerId = row['suggested_user_id'] as String;
    final peer = await _profiles.getProfile(peerId);
    if (peer == null) {
      _log.warn('peer $peerId missing — skipping suggestion ${row['id']}');
      return null;
    }
    return WeeklySuggestion(
      id: row['id'] as String,
      userId: row['user_id'] as String,
      suggestedUserId: peerId,
      compatibilityScore: (row['compatibility_score'] as num).toInt(),
      weekStartDate: DateTime.parse(row['week_start_date'] as String).toUtc(),
      status: _statusFromWire(row['status'] as String?),
      createdAt: DateTime.parse(row['created_at'] as String).toUtc(),
      candidate: peer,
      // The table has no distance column, and the only distance we can
      // compute today is a random draw. Persisting it would freeze an
      // invented figure in Postgres; recomputing it per emission would make
      // the card flicker between numbers. So it stays 0 and the card hides
      // the line — real distances arrive with the geo work (point 3b/3c).
      distanceKm: 0,
    );
  }

  @override
  Stream<List<MutualMatch>> watchMatches(String userId) =>
      _matches.watch(userId);

  // -------------------------------------------------------------------
  // Weekly batch
  // -------------------------------------------------------------------

  @override
  Future<void> ensureWeeklyBatch(UserProfile self) async {
    final weekStart = _currentWeekStart();
    final week = _weekKey(weekStart);

    final current = await _client
        .from(_table)
        .select('id')
        .eq('user_id', self.userId)
        .eq('week_start_date', week)
        .neq('status', 'dismissed');

    final missing = WeeklySuggestionsService.weeklySlots - current.length;
    if (missing <= 0) {
      _log.info('week $week already full (${current.length})');
      return;
    }

    final excluded = await _exclusions(self.userId);
    _log.info('week $week — ${current.length} kept, $missing to fill, '
        '${excluded.length} peers excluded');

    final pool = <({UserProfile candidate, int distanceKm})>[];
    try {
      final reals = await _profiles.fetchPotentialCandidates(
        selfUserId: self.userId,
      );
      for (final c in reals) {
        pool.add((candidate: c, distanceKm: _factory.distanceFor(self)));
      }
    } catch (e, st) {
      _log.error('candidate fetch failed — no batch this round', e, st);
      return;
    }

    if (pool.isEmpty) {
      // Deliberately NOT falling back to the synthetic factory: a persisted
      // suggestion pointing at a profile id that does not exist in
      // `profiles` would violate the FK and, worse, put a fabricated person
      // in the database.
      _log.info('no real candidate available — nothing written');
      return;
    }

    final ranked = _service.selectFor(
      self: self,
      pool: pool,
      excludedUserIds: excluded,
    );
    if (ranked.isEmpty) {
      _log.info('pool exhausted by exclusions — nothing written');
      return;
    }

    final rows = ranked
        .take(missing)
        .map((r) => {
              'user_id': self.userId,
              'suggested_user_id': r.candidate.userId,
              'compatibility_score': r.score.percentage,
              'week_start_date': week,
              'status': 'pending',
            })
        .toList(growable: false);

    try {
      // onConflict on the table's own UNIQUE: two devices generating the
      // batch at the same moment converge instead of raising.
      await _client.from(_table).upsert(
            rows,
            onConflict: 'user_id,suggested_user_id,week_start_date',
          );
      _log.info('wrote ${rows.length} suggestion(s) for week $week');
    } catch (e, st) {
      _log.error('upsert failed for week $week', e, st);
    }
  }

  /// Everyone who must never be proposed: already suggested in any week,
  /// already matched, blocked either way, and already dated.
  Future<Set<String>> _exclusions(String selfUserId) async {
    final excluded = <String>{selfUserId};

    Future<void> collect(String label, Future<void> Function() f) async {
      try {
        await f();
      } catch (e, st) {
        // Best effort: a failing exclusion source must not stop the batch,
        // but it MUST be visible — silently dropping one is how a peer gets
        // re-proposed after being blocked.
        _log.error('exclusion source "$label" failed', e, st);
      }
    }

    await collect('suggestions', () async {
      final rows = await _client
          .from(_table)
          .select('suggested_user_id')
          .eq('user_id', selfUserId);
      excluded.addAll(rows.map((r) => r['suggested_user_id'] as String));
    });

    await collect('matches', () async {
      final rows = await _client
          .from('matches')
          .select('user_a_id, user_b_id')
          .or('user_a_id.eq.$selfUserId,user_b_id.eq.$selfUserId');
      for (final r in rows) {
        excluded.add(r['user_a_id'] as String);
        excluded.add(r['user_b_id'] as String);
      }
    });

    await collect('blocked', () async {
      final rows = await _client
          .from('blocked_users')
          .select('blocked_user_id')
          .eq('user_id', selfUserId);
      excluded.addAll(rows.map((r) => r['blocked_user_id'] as String));
    });

    await collect('calls', () async {
      excluded.addAll(await _fetchCalledPeerIds(_client, selfUserId));
    });

    return excluded;
  }

  // -------------------------------------------------------------------
  // Mutations
  // -------------------------------------------------------------------

  @override
  Future<void> dismissSuggestion(String suggestionId) =>
      _setStatus(suggestionId, SuggestionStatus.dismissed);

  @override
  Future<void> markSuggestionCallStarted(String suggestionId) =>
      _setStatus(suggestionId, SuggestionStatus.callStarted);

  @override
  Future<void> markSuggestionMatched(String suggestionId) =>
      _setStatus(suggestionId, SuggestionStatus.matched);

  Future<void> _setStatus(String id, SuggestionStatus status) async {
    try {
      await _client
          .from(_table)
          .update({'status': _statusToWire(status)}).eq('id', id);
      _log.info('suggestion $id → ${status.name}');
    } catch (e, st) {
      _log.error('status update failed for $id', e, st);
    }
  }

  /// The permanent match row is written server-side by
  /// `create_match_if_mutual` (cf. `RevealRepository.createMatch`), which
  /// re-checks that BOTH peers voted. Writing it from here would hand that
  /// power back to the client.
  @override
  Future<void> recordMutualMatch({
    required UserProfile self,
    required UserProfile candidate,
    required MatchScore score,
  }) async {
    _log.info('recordMutualMatch — no-op, the RPC owns `matches`');
  }

  @visibleForTesting
  static SuggestionStatus statusFromWire(String? wire) => _statusFromWire(wire);

  @visibleForTesting
  static String statusToWire(SuggestionStatus s) => _statusToWire(s);

  /// SQL `call_started` ↔ Dart `callStarted`; every other value matches
  /// `.name` verbatim.
  static SuggestionStatus _statusFromWire(String? wire) => switch (wire) {
        'call_started' => SuggestionStatus.callStarted,
        'dismissed' => SuggestionStatus.dismissed,
        'matched' => SuggestionStatus.matched,
        _ => SuggestionStatus.pending,
      };

  static String _statusToWire(SuggestionStatus s) => switch (s) {
        SuggestionStatus.callStarted => 'call_started',
        _ => s.name,
      };
}

// ---------------------------------------------------------------------------
// Provider
// ---------------------------------------------------------------------------

final discoverRepositoryProvider = Provider<DiscoverRepository>((ref) {
  final service = ref.watch(weeklySuggestionsServiceProvider);
  final supabaseUp = ref.watch(supabaseAvailableProvider);
  if (!supabaseUp) {
    // Demo / offline mode: everything stays in RAM, including the
    // synthetic candidate factory. Also the path the tests exercise.
    return MockDiscoverRepository(service);
  }
  // Supabase is configured: suggestions are persisted in
  // `weekly_suggestions` and matches are read from `matches`. The weekly
  // batch used to live in a Map that reset on every app restart, which
  // re-proposed people the user had already seen.
  return SupabaseDiscoverRepository(
    client: ref.watch(supabaseClientProvider),
    service: service,
    profiles: ref.watch(profileRepositoryProvider),
    factory: MockCandidateFactory(),
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
