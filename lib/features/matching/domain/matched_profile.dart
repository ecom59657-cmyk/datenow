import '../../profile_setup/domain/interest.dart';

/// Minimal, read-only profile card returned by the `get_matched_profile`
/// RPC — only the fields safe to show a matched peer. Access is enforced
/// server-side (an active match must exist); this model never carries
/// birth_date, email, phone, location, KYC or message data.
class MatchedProfile {
  const MatchedProfile({
    required this.userId,
    required this.firstName,
    required this.age,
    required this.compatibilityScore,
    required this.mainPhotoPath,
    required this.interests,
  });

  final String userId;
  final String? firstName;

  /// Completed years — computed server-side from birth_date, which is never
  /// sent to the client.
  final int? age;

  /// 0-100 compatibility from the `matches` row.
  final int compatibilityScore;

  /// Storage path in the private `profile-photos` bucket. The bytes are
  /// downloaded client-side through the existing matched-gated storage RLS
  /// (see [ProfileRepository.getPhotoBytes]). Null when the peer has no
  /// moderation-approved photo.
  final String? mainPhotoPath;

  /// Interests that mapped to a known [Interest] enum value. Unknown / legacy
  /// strings are dropped rather than rendered raw.
  final List<Interest> interests;

  /// Parses one row of the `get_matched_profile` RPC result.
  factory MatchedProfile.fromRpc(Map<String, dynamic> json) {
    final rawInterests = (json['interests'] as List?) ?? const <dynamic>[];
    final interests = <Interest>[];
    for (final raw in rawInterests) {
      final name = raw?.toString();
      if (name == null) continue;
      for (final interest in Interest.values) {
        if (interest.name == name) {
          interests.add(interest);
          break;
        }
      }
    }
    return MatchedProfile(
      userId: json['user_id'] as String,
      firstName: json['first_name'] as String?,
      age: (json['age'] as num?)?.toInt(),
      compatibilityScore: (json['compatibility_score'] as num?)?.toInt() ?? 0,
      mainPhotoPath: json['main_photo_path'] as String?,
      interests: interests,
    );
  }
}
