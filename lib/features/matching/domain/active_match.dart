import '../../profile_setup/domain/user_profile.dart';
import 'match_score.dart';

/// One-shot in-memory state for "the person we just matched with".
///
/// Stays alive across the matching → call → post-call screens, then is
/// cleared when the user goes home or starts a new search.
class ActiveMatch {
  const ActiveMatch({
    required this.candidate,
    required this.distanceKm,
    required this.score,
    this.sourceSuggestionId,
  });

  final UserProfile candidate;
  final int distanceKm;
  final MatchScore score;

  /// Set when the match was started from a Discover suggestion. Lets the
  /// post-call screen flip that suggestion's status to `matched` if the
  /// peer accepts.
  final String? sourceSuggestionId;
}
