import 'package:freezed_annotation/freezed_annotation.dart';

import '../../profile_setup/domain/user_profile.dart';
import 'suggestion_status.dart';

part 'weekly_suggestion.freezed.dart';

/// One of the (at most 3) weekly proposals shown in the Discover tab.
///
/// Mirrors the future Supabase shape:
/// ```
/// suggestions(id, user_id, suggested_user_id, compatibility_score,
///             week_start_date, status, created_at)
/// ```
/// `candidate` and `distanceKm` are inlined here for the mock so the UI can
/// render without a join — on Supabase they would be loaded separately.
@freezed
class WeeklySuggestion with _$WeeklySuggestion {
  const factory WeeklySuggestion({
    required String id,
    required String userId,
    required String suggestedUserId,
    required int compatibilityScore,
    required DateTime weekStartDate,
    required SuggestionStatus status,
    required DateTime createdAt,
    required UserProfile candidate,
    required int distanceKm,
  }) = _WeeklySuggestion;
}
