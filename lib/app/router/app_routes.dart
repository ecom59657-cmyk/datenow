/// All named routes in DateNow. Keeps route names + paths in a single place
/// so we never have stringly-typed mismatches between calls and definitions.
enum AppRoute {
  splash('/splash'),
  onboarding('/onboarding'),
  authLanding('/auth'),
  signIn('/auth/sign-in'),
  signUp('/auth/sign-up'),
  home('/home'),
  discover('/discover'),
  profile('/profile'),
  settings('/settings'),
  matching('/matching'),
  call('/call');

  const AppRoute(this.path);

  final String path;
}
