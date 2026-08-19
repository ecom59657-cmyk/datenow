import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/logger.dart';
import '../../matching/data/matching_repository.dart';
import '../../matching/data/matching_service.dart';
import '../../matching/domain/match_score.dart';
import '../../profile_setup/domain/user_profile.dart';

/// Compact rank result used by the discover repository when building the
/// weekly batch.
typedef RankedCandidate = ({
  UserProfile candidate,
  int distanceKm,
  MatchScore score,
});

/// Pure business policy for the weekly suggestions feature.
///
/// Owns two responsibilities:
/// - computing the "Monday at 00:00" anchor that identifies a week
/// - turning a pool of candidates + their geo distance into a ranked list
///   of suggestions, keeping only those at or above the compatibility floor
class WeeklySuggestionsService {
  const WeeklySuggestionsService(this._matchingService);

  final MatchingService _matchingService;

  static const _log = AppLogger('WeeklySuggest');

  /// Minimum compatibility score required for a candidate to be proposed.
  /// Was 75 when every score carried the orientation axis's free 15
  /// points. Dropping to 60 keeps the selectivity exactly where it was
  /// rather than tightening it by stealth — 75 on an inflated score is 60
  /// on a deflated one. Watch the `belowFloor=` log at real volume before
  /// moving it again.
  static const int minCompatibility = 60;

  /// Maximum number of suggestions kept for the week.
  static const int weeklySlots = 3;

  /// Anchors a date to the **UTC** Monday at 00:00:00 — used as the
  /// week's identifier in storage so re-opens within the same week
  /// see the same batch and a fresh Monday triggers a regeneration.
  ///
  /// The week boundary is computed in UTC on purpose : it must agree
  /// across every client (Paris, NYC, Tokyo) and the eventual server-
  /// side suggestion-reset cron job. Local-time week math previously
  /// desync'd those — a user in Tokyo (UTC+9) at 00:05 local would
  /// land on Monday while a user in NYC (UTC-5) at 10:05 PM the
  /// previous calendar day would land on the previous Sunday, even
  /// though both timestamps represent the same UTC instant.
  ///
  /// Input is normalised to UTC ; output is a UTC DateTime so any
  /// caller comparing against it must also be UTC-aware (use
  /// `DateTime.now().toUtc()` or the `.isUtc` getter to verify).
  static DateTime startOfWeek(DateTime now) {
    final utc = now.toUtc();
    final monday = utc.subtract(Duration(days: utc.weekday - 1));
    return DateTime.utc(monday.year, monday.month, monday.day);
  }

  /// Selects up to [weeklySlots] candidates from [pool], keeping only those
  /// scoring at least [minCompatibility]. Reciprocal hard gates are enforced
  /// by [MatchingService.calculateCompatibility]; a `null` score means the
  /// pair shouldn't be proposed in either direction.
  ///
  /// [excludedUserIds] lets the caller skip candidates already seen in
  /// previous weeks — dismissed, matched, call-started — so the same
  /// person is never re-offered. Comparison is by `UserProfile.userId`.
  ///
  /// Emits debug logs per candidate (hard-gate fail, below floor, kept)
  /// plus a summary line so we can audit why fewer than [weeklySlots]
  /// suggestions were retained.
  List<RankedCandidate> selectFor({
    required UserProfile self,
    required Iterable<({UserProfile candidate, int distanceKm})> pool,
    Set<String> excludedUserIds = const {},
  }) {
    final ranked = <RankedCandidate>[];
    final seenIds = <String>{};

    int total = 0;
    int duplicates = 0;
    int excluded = 0;
    int hardGateFails = 0;
    int belowFloor = 0;

    for (final entry in pool) {
      total++;
      final id = entry.candidate.userId;
      if (!seenIds.add(id)) {
        duplicates++;
        continue;
      }
      if (excludedUserIds.contains(id)) {
        excluded++;
        continue;
      }
      final score = _matchingService.calculateCompatibility(
        self,
        entry.candidate,
        distanceKm: entry.distanceKm,
      );
      if (score == null) {
        hardGateFails++;
        continue;
      }
      if (score.percentage < minCompatibility) {
        belowFloor++;
        continue;
      }
      ranked.add((
        candidate: entry.candidate,
        distanceKm: entry.distanceKm,
        score: score,
      ));
    }

    ranked.sort(
      (a, b) => b.score.percentage.compareTo(a.score.percentage),
    );
    final kept = ranked.take(weeklySlots).toList(growable: false);

    _log.info(
      'selectFor self=${self.userId}: pool=$total dup=$duplicates '
      'excluded=$excluded hardGateFail=$hardGateFails '
      'belowFloor=$belowFloor eligible=${ranked.length} kept=${kept.length}',
    );
    for (final r in kept) {
      _log.info(
        '  ✓ ${r.candidate.userId} '
        'score=${r.score.percentage}% '
        'breakdown=${r.score.breakdown} '
        'distance=${r.distanceKm}km',
      );
    }

    return kept;
  }
}

final weeklySuggestionsServiceProvider = Provider<WeeklySuggestionsService>(
  (ref) => WeeklySuggestionsService(ref.watch(matchingServiceProvider)),
);
