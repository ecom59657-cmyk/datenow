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
  bool _busy = false;

  Future<void> _signInWithApple() async {
    if (_busy) return;
    setState(() => _busy = true);
    final ok = await ref.read(authControllerProvider.notifier).signInWithApple();
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) return;
    final err = ref.read(authControllerProvider).error;
    if (err is OAuthCancelledFailure) return;
    final l10n = AppLocalizations.of(context);
    final msg = err is Failure ? err.message : l10n.authAppleFailed;
    context.showSnack(msg);
  }

  Future<void> _signInWithGoogle() async {
    if (_busy) return;
    setState(() => _busy = true);
    final ok =
        await ref.read(authControllerProvider.notifier).signInWithGoogle();
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) return;
    final err = ref.read(authControllerProvider).error;
    if (err is OAuthCancelledFailure) return;
    final l10n = AppLocalizations.of(context);
    final msg = err is Failure ? err.message : l10n.authGoogleFailed;
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
          // (Apple HIG recommends white for dark backgrounds).
          SizedBox(
            height: 54,
            child: Opacity(
              opacity: _busy ? 0.6 : 1,
              child: SignInWithAppleButton(
                onPressed: _busy ? () {} : _signInWithApple,
                style: SignInWithAppleButtonStyle.white,
                text: l10n.authContinueWithApple,
                height: 54,
                borderRadius: const BorderRadius.all(Radius.circular(12)),
              ),
            ),
          ).animate().fadeIn(delay: 380.ms).slideY(begin: 0.2, end: 0),
          const SizedBox(height: AppSpacing.sm),
          // Google Sign In — sober premium style, matches the Apple
          // button's height + radius so the two CTAs read as one
          // vertical group.
          _GoogleSignInButton(
            label: l10n.authContinueWithGoogle,
            onPressed: _busy ? null : _signInWithGoogle,
          ).animate().fadeIn(delay: 460.ms).slideY(begin: 0.2, end: 0),
          const SizedBox(height: AppSpacing.md),
          // Email-OTP path (Create account / Sign in remain accessible).
          AppButton(
            label: l10n.authContinueWithEmail,
            size: AppButtonSize.large,
            variant: AppButtonVariant.secondary,
            onPressed: _busy
                ? null
                : () => context.pushNamed(AppRoute.signUp.name),
          ).animate().fadeIn(delay: 540.ms).slideY(begin: 0.2, end: 0),
          const SizedBox(height: AppSpacing.sm),
          Center(
            child: TextButton(
              onPressed: _busy
                  ? null
                  : () => context.pushNamed(AppRoute.signIn.name),
              child: Text(l10n.authHaveAccount),
            ),
          ).animate().fadeIn(delay: 620.ms),
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

/// Sober, premium-looking Google Sign In button. Matches the height +
/// radius of [SignInWithAppleButton] so Apple and Google read as one
/// vertical CTA group. Dark surface with a thin hairline border + the
/// classic multi-coloured "G" mark.
class _GoogleSignInButton extends StatelessWidget {
  const _GoogleSignInButton({
    required this.label,
    required this.onPressed,
  });

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 54,
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.hairline),
            ),
            padding:
                const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const _GoogleGMark(size: 20),
                const SizedBox(width: 10),
                Text(
                  label,
                  style: const TextStyle(
                    color: Color(0xFF1F1F1F),
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.2,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Tiny, dependency-free Google "G" mark — flat-coloured glyph drawn
/// with a [Stack] of [Container]s. Lighter than embedding the official
/// SVG asset for what's effectively decoration on a single button.
class _GoogleGMark extends StatelessWidget {
  const _GoogleGMark({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    // Use a unicode-ish letter "G" rendered in the Google brand blue.
    // This is intentionally minimalist — the official Google brand
    // guidelines allow a flat letter "G" in #4285F4 on a white surface
    // as a recognisable mark.
    return SizedBox(
      width: size,
      height: size,
      child: Center(
        child: Text(
          'G',
          style: TextStyle(
            color: const Color(0xFF4285F4),
            fontWeight: FontWeight.w700,
            fontSize: size,
            height: 1,
            letterSpacing: -1,
          ),
        ),
      ),
    );
  }
}
