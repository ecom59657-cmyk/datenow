import 'package:freezed_annotation/freezed_annotation.dart';

import '../../profile_setup/domain/user_profile.dart';
import 'match_status.dart';

part 'mutual_match.freezed.dart';

/// A successful, post-call, mutually-accepted match. Lives in the
/// "Confirmed matches" section of the Discover tab.
@freezed
class MutualMatch with _$MutualMatch {
  const factory MutualMatch({
    required String id,
    required String userId,
    required UserProfile candidate,
    required int compatibilityScore,
    required DateTime matchedAt,
    @Default(MatchStatus.newMatch) MatchStatus status,
  }) = _MutualMatch;
}
