import 'package:freezed_annotation/freezed_annotation.dart';

import '../../../core/utils/age.dart';
import 'enums.dart';
import 'prompt_answer.dart';
import 'interest.dart';

part 'user_profile.freezed.dart';

/// Full user profile assembled during the profile setup flow.
///
/// `birthDate` is the source of truth — the calendar age is derived from it
/// (and re-derived every time it's read, so the value can't drift). This
/// matches the database schema where `profiles.birth_date` is the column
/// and there is no `age` column.
@freezed
class UserProfile with _$UserProfile {
  const UserProfile._();

  const factory UserProfile({
    required String userId,
    String? firstName,
    DateTime? birthDate,
    Gender? gender,
    Orientation? orientation,
    @Default(<Gender>{}) Set<Gender> seekingGenders,
    @Default(18) int seekingAgeMin,
    @Default(40) int seekingAgeMax,
    @Default(50) int maxDistanceKm,
    @Default(<Intention>{}) Set<Intention> intentions,
    @Default(<Interest>{}) Set<Interest> interests,
    Availability? availability,
    @Default(<String>[]) List<String> photoUrls,
    @Default(<PromptAnswer>[]) List<PromptAnswer> prompts,
  }) = _UserProfile;

  /// Hard ceiling on the number of photos a profile can hold. Mirrors the
  /// constraint baked into the photos editor UI.
  static const int maxPhotos = 6;

  /// Answered prompts, in the order the user chose, blanks dropped.
  List<PromptAnswer> get filledPrompts => [
        ...prompts.where((p) => p.isFilled),
      ]..sort((a, b) => a.position.compareTo(b.position));

  /// The one surfaced on a Discover card and during the call.
  PromptAnswer? get leadPrompt =>
      filledPrompts.isEmpty ? null : filledPrompts.first;

  /// Primary photo — the one revealed after a 5-minute date.
  String? get primaryPhotoUrl =>
      photoUrls.isEmpty ? null : photoUrls.first;

  /// Calendar age computed from [birthDate]. `null` when the date isn't set.
  int? get age =>
      birthDate == null ? null : ageFromBirthDate(birthDate!);

  /// True when every required field is set. Drives the post-signup redirect.
  ///
  /// The 18+ floor is enforced here as well; even if `birthDate` is present,
  /// the profile is treated as incomplete (and matching is blocked) when
  /// it doesn't pass the age gate.
  bool get isComplete =>
      firstName != null &&
      firstName!.trim().isNotEmpty &&
      birthDate != null &&
      isOfMinimumAge(birthDate!) &&
      gender != null &&
      orientation != null &&
      seekingGenders.isNotEmpty &&
      intentions.isNotEmpty &&
      interests.length >= 3 &&
      availability != null;
}
