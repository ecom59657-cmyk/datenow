import 'package:freezed_annotation/freezed_annotation.dart';

part 'auth_user.freezed.dart';
part 'auth_user.g.dart';

/// Authenticated user — slim projection of a Supabase auth user.
///
/// We deliberately don't lean on Supabase's generated types here so the
/// presentation layer stays decoupled from the backend SDK.
@freezed
class AuthUser with _$AuthUser {
  const factory AuthUser({
    required String id,
    required String email,
    String? displayName,
    String? avatarUrl,
    DateTime? createdAt,
  }) = _AuthUser;

  factory AuthUser.fromJson(Map<String, dynamic> json) =>
      _$AuthUserFromJson(json);
}
