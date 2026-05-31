import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/auth/presentation/providers/auth_provider.dart';
import '../../features/auth/presentation/screens/auth_landing_screen.dart';
import '../../features/auth/presentation/screens/sign_in_screen.dart';
import '../../features/auth/presentation/screens/sign_up_screen.dart';
import '../../features/auth/presentation/screens/email_otp_screen.dart';
import '../../features/call/presentation/call_interrupted_screen.dart';
import '../../features/call/presentation/call_screen.dart';
import '../../features/discover/presentation/discover_screen.dart';
import '../../features/home/presentation/home_screen.dart';
import '../../features/matching/presentation/matching_screen.dart';
import '../../features/messaging/presentation/conversation_screen.dart';
import '../../features/messaging/presentation/inbox_screen.dart';
import '../../features/onboarding/presentation/onboarding_screen.dart';
import '../../features/onboarding/presentation/providers/onboarding_provider.dart';
import '../../features/post_call/presentation/post_call_screen.dart';
import '../../features/profile/presentation/edit/edit_photos_screen.dart';
import '../../features/profile/presentation/edit/edit_preferences_screen.dart';
import '../../features/profile/presentation/edit/edit_profile_screen.dart';
import '../../features/profile/presentation/profile_screen.dart';
import '../../features/permissions/presentation/permissions_screen.dart';
import '../../features/profile_setup/presentation/profile_setup_screen.dart';
import '../../features/settings/presentation/blocked_accounts_screen.dart';
import '../../features/settings/presentation/debug_datenow_screen.dart';
import '../../features/settings/presentation/debug_matching_screen.dart';
import '../../features/settings/presentation/help_screen.dart';
import '../../features/settings/presentation/legal/privacy_policy_screen.dart';
import '../../features/settings/presentation/legal/legal_terms_screen.dart';
import '../../features/settings/presentation/notifications_screen.dart';
import '../../features/settings/presentation/privacy_screen.dart';
import '../../features/settings/presentation/security_screen.dart';
import '../../features/subscription/presentation/subscription_screen.dart';
import '../../features/profile_setup/presentation/providers/profile_provider.dart';
import '../../features/settings/presentation/settings_screen.dart';
import '../../features/splash/presentation/splash_screen.dart';
import '../scaffold/main_shell.dart';
import 'app_routes.dart';

/// Global root navigator key — used by [PushNotificationsService] to
/// deep-link to a conversation from a notification tap (which happens
/// outside the widget tree, so we can't use BuildContext).
final GlobalKey<NavigatorState> rootNavigatorKey =
    GlobalKey<NavigatorState>(debugLabel: 'datenow-root');

/// Builds the GoRouter for the app and wires it to Riverpod so auth +
/// onboarding state can drive redirects.
final routerProvider = Provider<GoRouter>((ref) {
  final notifier = _RouterNotifier(ref);

  return GoRouter(
    navigatorKey: rootNavigatorKey,
    initialLocation: AppRoute.splash.path,
    refreshListenable: notifier,
    redirect: notifier.redirect,
    routes: [
      GoRoute(
        path: AppRoute.splash.path,
        name: AppRoute.splash.name,
        builder: (_, _) => const SplashScreen(),
      ),
      GoRoute(
        path: AppRoute.onboarding.path,
        name: AppRoute.onboarding.name,
        builder: (_, _) => const OnboardingScreen(),
      ),
      GoRoute(
        path: AppRoute.authLanding.path,
        name: AppRoute.authLanding.name,
        builder: (_, _) => const AuthLandingScreen(),
        routes: [
          GoRoute(
            path: 'sign-in',
            name: AppRoute.signIn.name,
            builder: (_, _) => const SignInScreen(),
          ),
          GoRoute(
            path: 'sign-up',
            name: AppRoute.signUp.name,
            builder: (_, _) => const SignUpScreen(),
          ),
          GoRoute(
            path: 'otp',
            name: AppRoute.emailOtp.name,
            builder: (_, state) {
              // EmailOtpArgs is passed via
              // `pushReplacementNamed(extra: EmailOtpArgs(...))`.
              final args = state.extra is EmailOtpArgs
                  ? state.extra as EmailOtpArgs
                  : const EmailOtpArgs(email: '', isSignup: false);
              return EmailOtpScreen(args: args);
            },
          ),
        ],
      ),

      // Profile-setup is a full-screen route gated by the auth+complete check.
      GoRoute(
        path: AppRoute.profileSetup.path,
        name: AppRoute.profileSetup.name,
        builder: (_, _) => const ProfileSetupScreen(),
      ),

      // Post-onboarding camera/mic permission ask. Reached once, right
      // after profile completion — never on every launch.
      GoRoute(
        path: AppRoute.permissions.path,
        name: AppRoute.permissions.name,
        builder: (_, _) => const PermissionsScreen(),
      ),

      // Authenticated stack — main shell with bottom nav + full-screen routes.
      StatefulShellRoute.indexedStack(
        builder: (_, _, navigationShell) =>
            MainShell(navigationShell: navigationShell),
        branches: [
          StatefulShellBranch(routes: [
            GoRoute(
              path: AppRoute.home.path,
              name: AppRoute.home.name,
              builder: (_, _) => const HomeScreen(),
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: AppRoute.discover.path,
              name: AppRoute.discover.name,
              builder: (_, _) => const DiscoverScreen(),
            ),
          ]),
          // Messages tab — root is the inbox; individual conversations
          // push as a full-screen route outside the shell.
          StatefulShellBranch(routes: [
            GoRoute(
              path: AppRoute.messages.path,
              name: AppRoute.messages.name,
              builder: (_, _) => const InboxScreen(),
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: AppRoute.profile.path,
              name: AppRoute.profile.name,
              builder: (_, _) => const ProfileScreen(),
            ),
          ]),
        ],
      ),

      // Full-screen routes outside the shell.
      GoRoute(
        path: AppRoute.editProfile.path,
        name: AppRoute.editProfile.name,
        builder: (_, _) => const EditProfileScreen(),
      ),
      GoRoute(
        path: AppRoute.editPreferences.path,
        name: AppRoute.editPreferences.name,
        builder: (_, _) => const EditPreferencesScreen(),
      ),
      GoRoute(
        path: AppRoute.editPhotos.path,
        name: AppRoute.editPhotos.name,
        builder: (_, _) => const EditPhotosScreen(),
      ),
      GoRoute(
        path: AppRoute.settings.path,
        name: AppRoute.settings.name,
        builder: (_, _) => const SettingsScreen(),
      ),
      GoRoute(
        path: AppRoute.settingsNotifications.path,
        name: AppRoute.settingsNotifications.name,
        builder: (_, _) => const NotificationsScreen(),
      ),
      GoRoute(
        path: AppRoute.settingsPrivacy.path,
        name: AppRoute.settingsPrivacy.name,
        builder: (_, _) => const PrivacyScreen(),
      ),
      GoRoute(
        path: AppRoute.settingsSecurity.path,
        name: AppRoute.settingsSecurity.name,
        builder: (_, _) => const SecurityScreen(),
      ),
      GoRoute(
        path: AppRoute.settingsBlocked.path,
        name: AppRoute.settingsBlocked.name,
        builder: (_, _) => const BlockedAccountsScreen(),
      ),
      GoRoute(
        path: AppRoute.settingsSubscription.path,
        name: AppRoute.settingsSubscription.name,
        builder: (_, _) => const SubscriptionScreen(),
      ),
      GoRoute(
        path: AppRoute.settingsHelp.path,
        name: AppRoute.settingsHelp.name,
        builder: (_, _) => const HelpScreen(),
      ),
      GoRoute(
        path: AppRoute.settingsTerms.path,
        name: AppRoute.settingsTerms.name,
        builder: (_, _) => const LegalTermsScreen(),
      ),
      GoRoute(
        path: AppRoute.settingsPrivacyPolicy.path,
        name: AppRoute.settingsPrivacyPolicy.name,
        builder: (_, _) => const PrivacyPolicyScreen(),
      ),
      // Diagnostic surfaces — registered ONLY in debug builds. In a
      // release / TestFlight build `kDebugMode` is a compile-time false,
      // so these routes don't exist at all (not even via deep link).
      if (kDebugMode)
        GoRoute(
          path: AppRoute.debugMatching.path,
          name: AppRoute.debugMatching.name,
          builder: (_, _) => const DebugMatchingScreen(),
        ),
      if (kDebugMode)
        GoRoute(
          path: AppRoute.debugDateNow.path,
          name: AppRoute.debugDateNow.name,
          builder: (_, _) => const DebugDateNowScreen(),
        ),
      GoRoute(
        path: AppRoute.matching.path,
        name: AppRoute.matching.name,
        builder: (_, _) => const MatchingScreen(),
      ),
      GoRoute(
        path: AppRoute.call.path,
        name: AppRoute.call.name,
        builder: (_, _) => const CallScreen(),
      ),
      GoRoute(
        path: AppRoute.postCall.path,
        name: AppRoute.postCall.name,
        builder: (_, _) => const PostCallScreen(),
      ),
      GoRoute(
        path: AppRoute.callInterrupted.path,
        name: AppRoute.callInterrupted.name,
        builder: (_, _) => const CallInterruptedScreen(),
      ),
      // /messages itself is the Messages tab inside the shell (above).
      // Only the per-conversation full-screen route remains outside.
      GoRoute(
        path: AppRoute.conversation.path,
        name: AppRoute.conversation.name,
        builder: (_, state) {
          final id = state.pathParameters['id']!;
          return ConversationScreen(conversationId: id);
        },
      ),
    ],
  );
});

/// Bridges Riverpod state changes into [GoRouter] via [ChangeNotifier].
///
/// GoRouter's [refreshListenable] needs a [Listenable]; we wrap [Ref] and
/// notify whenever auth, onboarding or profile-setup state changes so
/// [redirect] runs again.
class _RouterNotifier extends ChangeNotifier {
  _RouterNotifier(this._ref) {
    _ref.listen<AsyncValue<bool>>(
      onboardingCompletedProvider,
      (_, _) => notifyListeners(),
    );
    _ref.listen(authStateProvider, (_, _) => notifyListeners());
    _ref.listen(currentProfileProvider, (_, _) => notifyListeners());
  }

  final Ref _ref;

  String? redirect(BuildContext context, GoRouterState state) {
    final auth = _ref.read(authStateProvider);
    final onboarding = _ref.read(onboardingCompletedProvider);
    final profile = _ref.read(currentProfileProvider);
    return decideRedirect(
      authLoading: auth.isLoading,
      onboardingLoading: onboarding.isLoading,
      onboardingDone: onboarding.value ?? false,
      signedIn: auth.value != null,
      profileLoading: profile.isLoading,
      profileHasValue: profile.hasValue,
      profileComplete: profile.value?.isComplete ?? false,
      location: state.matchedLocation,
    );
  }
}

/// Pure routing decision — extracted out of [_RouterNotifier] so it can be
/// unit-tested with deterministic inputs. Returns the redirect target or
/// `null` to stay on [location].
///
/// The six gates, in order:
///   1. Auth or onboarding still loading → splash (never decide blind).
///   2. Onboarding not done yet → /onboarding.
///   3. Onboarded but not signed in → /auth.
///   4. Signed in but the profile stream is still loading → splash. We
///      trigger this on **any** AsyncLoading state, regardless of whether
///      `hasValue` is true. The historic condition `!profileHasValue` was
///      tuned for the brand-new cold start; it missed the more common
///      app-relaunch case where:
///        a. `currentProfileProvider` first emits a synthetic `null`
///           (the unauth branch returns `Stream.value(null)`),
///        b. then `currentUserProvider` resolves to the restored user,
///        c. `currentProfileProvider` rebuilds, Riverpod transitions to
///           `AsyncLoading(previous: AsyncData(null))` →
///           `profileLoading=true` AND `profileHasValue=true` AND
///           `value?.isComplete=false`.
///      Without this gate the router fell through to gate 5 and flashed
///      `/profile-setup` for ~300 ms before gate 6 corrected it. Holding
///      the splash for the same 300 ms is invisible UX-wise — the splash
///      was already rendered from gate 1 and stays put.
///   5. Signed in + profile decided but not complete → /profile-setup.
///   6. Signed in + profile complete → /home if currently on a pre-app
///      surface, else stay put.
@visibleForTesting
String? decideRedirect({
  required bool authLoading,
  required bool onboardingLoading,
  required bool onboardingDone,
  required bool signedIn,
  required bool profileLoading,
  required bool profileHasValue,
  required bool profileComplete,
  required String location,
}) {
  final isOnSplash = location == AppRoute.splash.path;
  final isOnOnboarding = location == AppRoute.onboarding.path;
  final isOnAuth = location.startsWith(AppRoute.authLanding.path);
  final isOnProfileSetup = location == AppRoute.profileSetup.path;

  // 0. Legal pages — always reachable, no gate may hijack them. Apple/Play
  //    review require legal links from any pre-auth surface; bumping the
  //    push off-route mid-transition reads as a broken app.
  if (location == AppRoute.settingsTerms.path ||
      location == AppRoute.settingsPrivacyPolicy.path) {
    return null;
  }

  // 1. Auth / onboarding loading → splash.
  if (authLoading || onboardingLoading) {
    return isOnSplash ? null : AppRoute.splash.path;
  }

  // 2. Onboarding gate.
  if (!onboardingDone && !isOnOnboarding) {
    return AppRoute.onboarding.path;
  }

  // 3. Auth gate.
  if (onboardingDone && !signedIn) {
    return isOnAuth ? null : AppRoute.authLanding.path;
  }

  // 4. Profile stream still loading → splash. Catches cold-start
  //    (no value yet) AND the unauth→auth rebuild (stale `null` carried
  //    as previous). `profileHasValue` stays on the signature for the
  //    existing tests but is intentionally NOT consulted here — see the
  //    doc comment above gate 4 for the full reasoning.
  if (signedIn && profileLoading) {
    return isOnSplash ? null : AppRoute.splash.path;
  }

  // 5. Signed in + profile decided but incomplete → /profile-setup.
  if (signedIn && !profileComplete) {
    return isOnProfileSetup ? null : AppRoute.profileSetup.path;
  }

  // 6. Signed in + profile complete: clear any pre-app surface.
  if (signedIn &&
      profileComplete &&
      (isOnSplash || isOnOnboarding || isOnAuth || isOnProfileSetup)) {
    return AppRoute.home.path;
  }

  return null;
}
