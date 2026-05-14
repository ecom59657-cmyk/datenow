import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/router/app_routes.dart';
import '../../../matching/data/matching_repository.dart';
import '../../../matching/domain/active_match.dart';
import '../../../matching/domain/match_score.dart';
import '../../../matching/presentation/providers/active_match_provider.dart';
import '../../../profile_setup/presentation/providers/profile_provider.dart';
import '../../../quota/data/quota_repository.dart';
import '../../../quota/presentation/widgets/quota_limit_sheet.dart';
import '../../data/discover_repository.dart';
import '../../domain/mutual_match.dart';
import '../../domain/weekly_suggestion.dart';

/// Streams the visible (non-dismissed) suggestions for the current week.
final weeklySuggestionsProvider =
    StreamProvider<List<WeeklySuggestion>>((ref) {
  final profile = ref.watch(currentProfileProvider).asData?.value;
  if (profile == null) {
    return Stream<List<WeeklySuggestion>>.value(const []);
  }
  return ref.watch(discoverRepositoryProvider).watchSuggestions(profile.userId);
});

/// Streams the user's confirmed mutual matches.
final mutualMatchesProvider = StreamProvider<List<MutualMatch>>((ref) {
  final profile = ref.watch(currentProfileProvider).asData?.value;
  if (profile == null) {
    return Stream<List<MutualMatch>>.value(const []);
  }
  return ref.watch(discoverRepositoryProvider).watchMatches(profile.userId);
});

/// Starts a live date from a Discover suggestion.
///
/// Gates on the daily quota first — if exhausted, shows the limit sheet and
/// no other state changes. Otherwise sets the active match, marks the
/// suggestion as `callStarted`, charges the quota, and navigates to the
/// call screen.
Future<void> startDateFromSuggestion(
  BuildContext context,
  WidgetRef ref,
  WeeklySuggestion suggestion,
) async {
  final self = ref.read(currentProfileProvider).asData?.value;
  if (self == null) return;

  final quotaRepo = ref.read(quotaRepositoryProvider);
  final status = await quotaRepo.currentStatus(self);
  if (!context.mounted) return;
  if (status.isExhausted) {
    await showQuotaLimitSheet(context);
    return;
  }

  // Recompute the score against the live `self` profile — preferences may
  // have changed since the suggestion was generated.
  final service = ref.read(matchingServiceProvider);
  final liveScore = service.calculateCompatibility(
    self,
    suggestion.candidate,
    distanceKm: suggestion.distanceKm,
  );
  final score = liveScore ??
      MatchScore(
        percentage: suggestion.compatibilityScore,
        breakdown: const {},
      );

  ref.read(activeMatchProvider.notifier).state = ActiveMatch(
    candidate: suggestion.candidate,
    distanceKm: suggestion.distanceKm,
    score: score,
    sourceSuggestionId: suggestion.id,
  );

  await ref
      .read(discoverRepositoryProvider)
      .markSuggestionCallStarted(suggestion.id);
  await quotaRepo.recordMatch(self);

  if (!context.mounted) return;
  context.pushNamed(AppRoute.call.name);
}
