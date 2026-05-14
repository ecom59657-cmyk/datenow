/// All named routes in DateNow. Keeps route names + paths in a single place
/// so we never have stringly-typed mismatches between calls and definitions.
enum AppRoute {
  splash('/splash'),
  onboarding('/onboarding'),
  authLanding('/auth'),
  signIn('/auth/sign-in'),
  signUp('/auth/sign-up'),
  verifyEmail('/auth/verify-email'),
  profileSetup('/profile-setup'),
  home('/home'),
  discover('/discover'),
  profile('/profile'),
  editProfile('/profile/edit'),
  editPreferences('/profile/preferences'),
  editPhotos('/profile/photos'),
  settings('/settings'),
  settingsNotifications('/settings/notifications'),
  settingsPrivacy('/settings/privacy'),
  settingsSecurity('/settings/security'),
  settingsBlocked('/settings/blocked'),
  settingsSubscription('/settings/subscription'),
  settingsHelp('/settings/help'),
  settingsTerms('/settings/terms'),
  settingsPrivacyPolicy('/settings/privacy-policy'),
  matching('/matching'),
  call('/call'),
  postCall('/post-call'),
  messages('/messages'),
  conversation('/messages/:id');

  const AppRoute(this.path);

  final String path;
}
