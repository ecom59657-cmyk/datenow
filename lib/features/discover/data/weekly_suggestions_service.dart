import 'package:flutter_riverpod/flutter_riverpod.dart';

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

  /// Minimum compatibility score required for a candidate to be proposed.
  static const int minCompatibility = 75;

  /// Maximum number of suggestions kept for the week.
  static const int weeklySlots = 3;

  /// Anchors a date to the local Monday at 00:00:00 — used as the week's
  /// identifier in storage so re-opens within the same week see the same
  /// batch and a fresh Monday triggers a regeneration.
  static DateTime startOfWeek(DateTime now) {
    final monday = now.subtract(Duration(days: now.weekday - 1));
    return DateTime(monday.year, monday.month, monday.day);
  }

  /// Selects up to [weeklySlots] candidates from [pool], keeping only those
  /// scoring at least [minCompatibility]. Reciprocal hard gates are enforced
  /// by [MatchingService.calculateCompatibility]; a `null` score means the
  /// pair shouldn't be proposed in either direction.
  List<RankedCandidate> selectFor({
    required UserProfile self,
    required Iterable<({UserProfile candidate, int distanceKm})> pool,
  }) {
    final ranked = <RankedCandidate>[];
    final seenIds = <String>{};

    for (final entry in pool) {
      if (!seenIds.add(entry.candidate.userId)) continue;
      final score = _matchingService.calculateCompatibility(
        self,
        entry.candidate,
        distanceKm: entry.distanceKm,
      );
      if (score == null) continue;
      if (score.percentage < minCompatibility) continue;
      ranked.add((
        candidate: entry.candidate,
        distanceKm: entry.distanceKm,
        score: score,
      ));
    }

    ranked.sort(
      (a, b) => b.score.percentage.compareTo(a.score.percentage),
    );
    return ranked.take(weeklySlots).toList(growable: false);
  }
}

final weeklySuggestionsServiceProvider = Provider<WeeklySuggestionsService>(
  (ref) => WeeklySuggestionsService(ref.watch(matchingServiceProvider)),
);
