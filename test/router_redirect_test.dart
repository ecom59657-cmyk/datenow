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
  bool splashMinElapsed = true,
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
    splashMinElapsed: splashMinElapsed,
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

  group('decideRedirect — legal pages always reachable', () {
    // Regression guard for the bug where an unsigned user on AuthLanding
    // tapped 'Conditions d'utilisation' / 'Politique de confidentialité',
    // the push iOS animation ran, then gate 3 ('!signedIn && not on
    // /auth/*') bumped them back to /auth/landing — the legal screen
    // was visible for ~0 frame, appearing as a transparent ghost over
    // AuthLanding.

    test('unsigned user can read terms (no redirect)', () {
      expect(
        r(signedIn: false, location: AppRoute.settingsTerms.path),
        isNull,
      );
    });

    test('unsigned user can read privacy policy (no redirect)', () {
      expect(
        r(signedIn: false, location: AppRoute.settingsPrivacyPolicy.path),
        isNull,
      );
    });

    test('signed-in user on legal route stays (no redirect to home)', () {
      expect(r(location: AppRoute.settingsTerms.path), isNull);
      expect(r(location: AppRoute.settingsPrivacyPolicy.path), isNull);
    });

    test(
        'legal route during onboarding (onboardingDone=false) → stay '
        '(rule of thumb: legal must be readable BEFORE accepting onboarding)',
        () {
      expect(
        r(
          onboardingDone: false,
          signedIn: false,
          location: AppRoute.settingsTerms.path,
        ),
        isNull,
      );
    });

    test(
        'legal route during auth loading (cold start race) → stay; '
        'we never hijack a tap on a legal link even before auth resolves',
        () {
      expect(
        r(authLoading: true, location: AppRoute.settingsTerms.path),
        isNull,
      );
    });
  });

  group('decideRedirect — premium splash min-duration floor (gate 0.5)', () {
    // The splash must stay visible for a minimum elegant window even when
    // auth/session restore resolves instantly. While the floor has not
    // elapsed (splashMinElapsed=false) we hold on /splash regardless of how
    // ready the rest of the state is.

    test('floor not elapsed + on /splash → stay (null), even if home-ready',
        () {
      // Fully signed-in + complete profile would normally go /home, but the
      // floor keeps us on the splash so the animation is seen.
      expect(r(splashMinElapsed: false, location: '/splash'), isNull);
    });

    test('floor not elapsed, signed out (would go /auth) → stay on splash',
        () {
      expect(
        r(splashMinElapsed: false, signedIn: false, location: '/splash'),
        isNull,
      );
    });

    test('floor not elapsed, first-install (would go /onboarding) → stay',
        () {
      expect(
        r(
          splashMinElapsed: false,
          onboardingDone: false,
          signedIn: false,
          location: '/splash',
        ),
        isNull,
      );
    });

    test('floor not elapsed but NOT on splash → no hold (never sends to splash)',
        () {
      // The gate only prolongs an existing splash; it must not hijack
      // in-app navigation, so off-splash it is a no-op and normal gates win.
      expect(
        r(splashMinElapsed: false, location: '/home'),
        isNull, // signed-in + complete + on /home → steady state
      );
    });

    test('floor elapsed → splash releases to /home', () {
      expect(r(splashMinElapsed: true, location: '/splash'),
          AppRoute.home.path);
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
