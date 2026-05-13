import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/auth/presentation/providers/auth_provider.dart';
import '../../features/auth/presentation/screens/auth_landing_screen.dart';
import '../../features/auth/presentation/screens/sign_in_screen.dart';
import '../../features/auth/presentation/screens/sign_up_screen.dart';
import '../../features/call/presentation/call_screen.dart';
import '../../features/discover/presentation/discover_screen.dart';
import '../../features/home/presentation/home_screen.dart';
import '../../features/matching/presentation/matching_screen.dart';
import '../../features/onboarding/presentation/onboarding_screen.dart';
import '../../features/onboarding/presentation/providers/onboarding_provider.dart';
import '../../features/profile/presentation/profile_screen.dart';
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
        ],
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
        path: AppRoute.settings.path,
        name: AppRoute.settings.name,
        builder: (_, _) => const SettingsScreen(),
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
    ],
  );
});

/// Bridges Riverpod state changes into [GoRouter] via [ChangeNotifier].
///
/// GoRouter's [refreshListenable] needs a [Listenable]; we wrap [Ref] and
/// notify whenever auth or onboarding state changes, so [redirect] runs again.
class _RouterNotifier extends ChangeNotifier {
  _RouterNotifier(this._ref) {
    _ref.listen<AsyncValue<bool>>(
      onboardingCompletedProvider,
      (_, _) => notifyListeners(),
    );
    _ref.listen(authStateProvider, (_, _) => notifyListeners());
  }

  final Ref _ref;

  String? redirect(BuildContext context, GoRouterState state) {
    final auth = _ref.read(authStateProvider);
    final onboarding = _ref.read(onboardingCompletedProvider);

    // Wait for both async providers to resolve once before navigating away
    // from the splash screen.
    if (auth.isLoading || onboarding.isLoading) {
      return state.matchedLocation == AppRoute.splash.path
          ? null
          : AppRoute.splash.path;
    }

    final location = state.matchedLocation;
    final isOnSplash = location == AppRoute.splash.path;
    final isOnOnboarding = location == AppRoute.onboarding.path;
    final isOnAuth = location.startsWith(AppRoute.authLanding.path);

    final onboardingDone = onboarding.value ?? false;
    final user = auth.value;

    // 1) Onboarding first.
    if (!onboardingDone && !isOnOnboarding) {
      return AppRoute.onboarding.path;
    }

    // 2) Then auth.
    if (onboardingDone && user == null) {
      return isOnAuth ? null : AppRoute.authLanding.path;
    }

    // 3) Authenticated: never sit on splash/onboarding/auth.
    if (user != null && (isOnSplash || isOnOnboarding || isOnAuth)) {
      return AppRoute.home.path;
    }

    return null;
  }
}
