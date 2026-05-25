import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/auth/presentation/providers/auth_provider.dart';
import '../../features/auth/presentation/screens/auth_landing_screen.dart';
import '../../features/auth/presentation/screens/sign_in_screen.dart';
import '../../features/auth/presentation/screens/sign_up_screen.dart';
import '../../features/auth/presentation/screens/verify_email_screen.dart';
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
import '../../features/settings/presentation/legal/terms_screen.dart';
import '../../features/settings/presentation/notifications_screen.dart';
import '../../features/settings/presentation/privacy_screen.dart';
import '../../features/settings/presentation/security_screen.dart';
import '../../features/subscription/presentation/subscription_screen.dart';
import '../../features/profile_setup/presentation/providers/profile_provider.dart';
import '../../features/settings/presentation/settings_screen.dart';
import '../../features/splash/presentation/splash_screen.dart';
import '../scaffold/main_shell.dart';
import 'app_routes.dart';

/// Builds the GoRouter for the app and wires it to Riverpod so auth +
/// onboarding state can drive redirects.
final routerProvider = Provider<GoRouter>((ref) {
  final notifier = _RouterNotifier(ref);

  return GoRouter(
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
            path: 'verify-email',
            name: AppRoute.verifyEmail.name,
            builder: (_, state) {
              // Email is passed via `pushReplacementNamed(extra: email)`.
              final email = state.extra is String ? state.extra as String : '';
              return VerifyEmailScreen(email: email);
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
        builder: (_, _) => const TermsScreen(),
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
/// The five gates, in order:
///   1. Auth or onboarding still loading → splash (never decide blind).
///   2. Onboarding not done yet → /onboarding.
///   3. Onboarded but not signed in → /auth.
///   4. Signed in but the profile stream hasn't emitted yet → splash.
///      ⚠ Returning users have a fully-completed profile in DB but it
///      takes one round-trip to fetch on cold start; if we treated that
///      loading window as "no profile" the router would bounce them to
///      ProfileSetup 1/4 — the exact bug this layout exists to prevent.
///   5. Signed in + profile loaded but not complete → /profile-setup.
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

  // 4. Profile stream still loading (returning user, cold start) → splash.
  if (signedIn && profileLoading && !profileHasValue) {
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
