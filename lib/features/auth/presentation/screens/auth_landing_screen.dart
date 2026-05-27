import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import '../../../../app/router/app_routes.dart';
import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_spacing.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../core/errors/failures.dart';
import '../../../../core/utils/extensions.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../../shared/widgets/app_button.dart';
import '../../../../shared/widgets/app_logo.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../data/auth_repository.dart';
import '../providers/auth_provider.dart';

/// Entry point of the auth flow — Apple Sign In, Google Sign In (next
/// sub-phase), email OTP. Apple HIG: when ANY third-party auth is
/// offered, Sign in with Apple must be at the same level, with the
/// official button style + clear copy. We honor that here.
class AuthLandingScreen extends ConsumerStatefulWidget {
  const AuthLandingScreen({super.key});

  @override
  ConsumerState<AuthLandingScreen> createState() =>
      _AuthLandingScreenState();
}

class _AuthLandingScreenState extends ConsumerState<AuthLandingScreen> {
  bool _appleBusy = false;

  Future<void> _signInWithApple() async {
    if (_appleBusy) return;
    setState(() => _appleBusy = true);
    final ok = await ref.read(authControllerProvider.notifier).signInWithApple();
    if (!mounted) return;
    setState(() => _appleBusy = false);
    if (ok) {
      // Auth-state stream will emit; router redirect handles the next
      // screen (profile-setup if Apple user lacks first_name/birth_date,
      // home otherwise).
      return;
    }
    final err = ref.read(authControllerProvider).error;
    // Silent on cancel — that's a user choice, not a failure.
    if (err is OAuthCancelledFailure) return;
    final l10n = AppLocalizations.of(context);
    final msg = err is Failure ? err.message : l10n.authAppleFailed;
    context.showSnack(msg);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AppScaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Spacer(flex: 2),
          Center(child: const AppLogo(fontSize: 44))
              .animate()
              .fadeIn(duration: 600.ms)
              .slideY(begin: 0.15, end: 0, curve: Curves.easeOutCubic),
          const SizedBox(height: AppSpacing.lg),
          Text(
            '${l10n.authTaglineLine1}\n${l10n.authTaglineLine2}',
            textAlign: TextAlign.center,
            style: AppTypography.body.copyWith(
              color: AppColors.textSecondary,
              fontSize: 16,
              height: 1.5,
            ),
          ).animate().fadeIn(delay: 200.ms, duration: 600.ms),
          const Spacer(flex: 3),
          // Apple Sign In — official button widget from the
          // sign_in_with_apple package. Style: white on dark surface
          // (Apple HIG recommends white for dark backgrounds). Height
          // matches AppButton.large for visual parity.
          SizedBox(
            height: 54,
            child: Opacity(
              opacity: _appleBusy ? 0.6 : 1,
              child: SignInWithAppleButton(
                onPressed: _appleBusy ? () {} : _signInWithApple,
                style: SignInWithAppleButtonStyle.white,
                text: l10n.authContinueWithApple,
                height: 54,
                borderRadius: const BorderRadius.all(Radius.circular(12)),
              ),
            ),
          ).animate().fadeIn(delay: 380.ms).slideY(begin: 0.2, end: 0),
          const SizedBox(height: AppSpacing.sm),
          // Email-OTP path (Create account / Sign in remain accessible).
          AppButton(
            label: l10n.authContinueWithEmail,
            size: AppButtonSize.large,
            variant: AppButtonVariant.secondary,
            onPressed: _appleBusy
                ? null
                : () => context.pushNamed(AppRoute.signUp.name),
          ).animate().fadeIn(delay: 460.ms).slideY(begin: 0.2, end: 0),
          const SizedBox(height: AppSpacing.sm),
          Center(
            child: TextButton(
              onPressed: _appleBusy
                  ? null
                  : () => context.pushNamed(AppRoute.signIn.name),
              child: Text(l10n.authHaveAccount),
            ),
          ).animate().fadeIn(delay: 540.ms),
          const SizedBox(height: AppSpacing.lg),
          // Apple expects easy access to Terms + Privacy from any
          // pre-auth surface. Keep the legal sentence above the two
          // tappable links.
          Text(
            l10n.authTerms,
            textAlign: TextAlign.center,
            style: AppTypography.caption,
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              TextButton(
                onPressed: () =>
                    context.pushNamed(AppRoute.settingsTerms.name),
                child: Text(l10n.settingsTerms),
              ),
              const Text('·',
                  style: TextStyle(color: AppColors.textTertiary)),
              TextButton(
                onPressed: () =>
                    context.pushNamed(AppRoute.settingsPrivacyPolicy.name),
                child: Text(l10n.settingsPrivacyPolicy),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
        ],
      ),
    );
  }
}
