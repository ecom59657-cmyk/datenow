import '../../features/auth/domain/auth_user.dart';
import '../../features/profile_setup/domain/user_profile.dart';

/// Picks the human name to surface anywhere the user's identity is
/// shown (Home greeting, Profile card, sheets, etc.). Hard rule:
/// **never display an email-shaped value as the user's name**.
/// Apple Private Relay aliases like
/// `ttsfv4hm22@privaterelay.appleid.com` count as emails and would
/// leak through any naive `displayName ?? email` fallback — the
/// `.contains('@')` guard below blocks all of them.
///
/// Precedence:
///   1. `profile.firstName`  — what the user typed in onboarding
///      step 1/4, persisted to `public.profiles.first_name`. The
///      streaming `currentProfileProvider` refreshes the screen the
///      moment this row is written, so post-onboarding the name flips
///      automatically with no manual refresh.
///   2. `user.displayName`   — fallback from `auth.users.raw_user_meta_data`.
///      Rejected when it contains `@` so a stray email-shaped value
///      (e.g. a Google / OTP path that happened to put the address in
///      display_name) can never reach the UI.
///   3. `null`              — caller is expected to show a localised
///      welcome / brand string (`homeFallbackName`,
///      `profileAnonymousName`, …). NEVER show an email here.
///
/// Pure function so it stays testable + cheap to call in `build`.
String? resolveUserDisplayName(UserProfile? profile, AuthUser? user) {
  final fromProfile = profile?.firstName?.trim();
  if (fromProfile != null && fromProfile.isNotEmpty) return fromProfile;
  final fromAuth = user?.displayName?.trim();
  if (fromAuth != null && fromAuth.isNotEmpty && !fromAuth.contains('@')) {
    return fromAuth;
  }
  return null;
}
