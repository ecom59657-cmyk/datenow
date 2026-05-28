// Routing decisions for DateNow's GoRouter — exercised through the pure
// `decideRedirect` helper so each state combination is testable without
// mounting providers.
//
// Regression guard for the cold-start bug where a returning user with a
// fully-completed profile landed on ProfileSetup 1/4 because the profile
// stream hadn't emitted yet when the redirect first ran.

import 'package:datenow/app/router/app_router.dart';
import 'package:datenow/app/router/app_routes.dart';
import 'package:flutter_test/flutter_test.dart';

/// Sensible defaults so each test only spells out what it changes.
String? r({
  bool authLoading = false,
  bool onboardingLoading = false,
  bool onboardingDone = true,
  bool signedIn = true,
  bool profileLoading = false,
  bool profileHasValue = true,
  bool profileComplete = true,
  String location = '/splash',
}) {
  return decideRedirect(
    authLoading: authLoading,
    onboardingLoading: onboardingLoading,
    onboardingDone: onboardingDone,
    signedIn: signedIn,
    profileLoading: profileLoading,
    profileHasValue: profileHasValue,
    profileComplete: profileComplete,
    location: location,
  );
}

void main() {
  group('decideRedirect — loading gates', () {
    test('auth still loading → splash', () {
      expect(r(authLoading: true, location: '/home'), AppRoute.splash.path);
    });

    test('onboarding still loading → splash', () {
      expect(r(onboardingLoading: true, location: '/home'),
          AppRoute.splash.path);
    });

    test('already on splash + still loading → stay (null)', () {
      expect(r(authLoading: true, location: '/splash'), isNull);
    });
  });

  group('decideRedirect — onboarding & auth', () {
    test('onboarding not done → /onboarding', () {
      expect(
        r(onboardingDone: false, signedIn: false, location: '/auth'),
        AppRoute.onboarding.path,
      );
    });

    test('onboarded but not signed in → /auth', () {
      expect(
        r(signedIn: false, location: '/home'),
        AppRoute.authLanding.path,
      );
    });

    test('on an /auth sub-route while not signed in → stay (null)', () {
      expect(r(signedIn: false, location: '/auth/sign-in'), isNull);
    });
  });

  group('decideRedirect — cold-start regression guard', () {
    // The bug: a returning user with a complete profile in DB was bounced
    // to ProfileSetup 1/4 because the profile stream was still loading
    // when the redirect ran. The fix: hold the splash until the stream
    // has actually decided.

    test('signed in + profile stream still loading (no value yet) → splash',
        () {
      expect(
        r(
          profileLoading: true,
          profileHasValue: false,
          profileComplete: false, // doesn't matter — provider lies during load
          location: '/home',
        ),
        AppRoute.splash.path,
      );
    });

    test('already on splash while profile loads → stay (null)', () {
      expect(
        r(
          profileLoading: true,
          profileHasValue: false,
          profileComplete: false,
          location: '/splash',
        ),
        isNull,
      );
    });

    test(
        'profile finished loading with a complete row → /home, NOT /profile-setup',
        () {
      // The exact scenario that used to break: user reopens the app,
      // session restored, profile arrives complete → must land on home.
      expect(r(location: '/splash'), AppRoute.home.path);
      expect(r(location: '/auth'), AppRoute.home.path);
      expect(r(location: '/profile-setup'), AppRoute.home.path);
    });

    test(
        'app cold-start unauth→auth transition: profileLoading=true AND '
        'profileHasValue=true (stale null from previous unauth emission) '
        '→ splash, NOT /profile-setup', () {
      // The bug: on app relaunch (the system killed the previous instance),
      // currentProfileProvider first builds Stream.value(null) for the
      // unauth user (state = AsyncData(null) → hasValue=true), then
      // rebuilds when authStateProvider emits the restored user. Riverpod
      // surfaces that rebuild as AsyncLoading(previous: AsyncData(null))
      // → profileLoading=true AND profileHasValue=true AND
      // value?.isComplete=false. Pre-fix, gate 4 had `!profileHasValue`
      // so it didn't fire; the router fell through to gate 5 and
      // flashed `/profile-setup` for ~300 ms before the real row arrived
      // and gate 6 corrected to /home. This test locks the fix.
      expect(
        r(
          profileLoading: true,
          profileHasValue: true,
          profileComplete: false,
          location: '/home',
        ),
        AppRoute.splash.path,
      );
    });

    test(
        'app cold-start: same scenario but already on /splash → stay (null)',
        () {
      expect(
        r(
          profileLoading: true,
          profileHasValue: true,
          profileComplete: false,
          location: '/splash',
        ),
        isNull,
      );
    });
  });

  group('decideRedirect — first-time user', () {
    test('signed in + profile stream resolved with NO profile → /profile-setup',
        () {
      expect(
        r(profileComplete: false, location: '/home'),
        AppRoute.profileSetup.path,
      );
    });

    test('signed in + profile resolved but isComplete=false → /profile-setup',
        () {
      expect(
        r(profileComplete: false, location: '/home'),
        AppRoute.profileSetup.path,
      );
    });

    test('already on /profile-setup while incomplete → stay (null)', () {
      expect(
        r(profileComplete: false, location: '/profile-setup'),
        isNull,
      );
    });
  });

  group('decideRedirect — settled / steady state', () {
    test('signed in + complete + on /home → stay (null)', () {
      expect(r(location: '/home'), isNull);
    });

    test('signed in + complete + on /discover → stay (null)', () {
      expect(r(location: '/discover'), isNull);
    });

    test('signed in + complete + on /messages → stay (null)', () {
      expect(r(location: '/messages'), isNull);
    });
  });
}
