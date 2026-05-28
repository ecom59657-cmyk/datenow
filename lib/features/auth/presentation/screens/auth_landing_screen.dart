import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/router/app_routes.dart';
import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_spacing.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../core/config/env.dart';
import '../../../../core/utils/extensions.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../../shared/widgets/app_button.dart';
import '../../../../shared/widgets/app_logo.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../data/auth_repository.dart';
import '../providers/auth_provider.dart';
import '../utils/auth_error_mapper.dart';
import '../widgets/oauth_button.dart';

/// Entry point of the auth flow — Apple Sign In, Google Sign In, email
/// OTP. The three buttons are visually consistent (52 dp height, 14 dp
/// radius, single-line label with ellipsis fade, light haptic + spring
/// press feedback) so they read as one Apple-native CTA group rather
/// than three loose widgets.
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
    final ok =
        await ref.read(authControllerProvider.notifier).signInWithApple();
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) return;
    final err = ref.read(authControllerProvider).error;
    if (err is OAuthCancelledFailure) return;
    final l10n = AppLocalizations.of(context);
    // TEMP — `includeRaw: true` appends the underlying Supabase /
    // SDK message after the humane string so on-screen errors carry
    // the real cause during the OAuth diagnostic phase. Flip back to
    // false (or drop the param entirely) once Apple + Google are
    // green end-to-end on TestFlight.
    context.showSnack(
      humaneAuthError(
        err,
        l10n,
        fallback: AuthFallback.oauthApple,
        includeRaw: true,
      ),
    );
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
    // TEMP — same diagnostic mode as the Apple path above. Drop
    // `includeRaw: true` once OAuth is stable.
    context.showSnack(
      humaneAuthError(
        err,
        l10n,
        fallback: AuthFallback.oauthGoogle,
        includeRaw: true,
      ),
    );
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
          // Apple — top of the OAuth group (Apple HIG: if Google is
          // offered, Apple must be at least as prominent).
          if (Env.appleSignInConfigured) ...[
            AppleSignInButton(
              label: l10n.authContinueWithApple,
              onPressed: _busy ? null : _signInWithApple,
            ).animate().fadeIn(delay: 380.ms).slideY(begin: 0.2, end: 0),
            const SizedBox(height: 10),
          ],
          if (Env.googleSignInConfigured) ...[
            GoogleSignInButton(
              label: l10n.authContinueWithGoogle,
              onPressed: _busy ? null : _signInWithGoogle,
            ).animate().fadeIn(delay: 460.ms).slideY(begin: 0.2, end: 0),
            const SizedBox(height: AppSpacing.md),
          ] else if (Env.appleSignInConfigured) ...[
            const SizedBox(height: AppSpacing.sm),
          ],
          // Email-OTP path. Visually demoted below the OAuth pair —
          // narrower (secondary variant) so it doesn't compete with
          // the safer-feeling Apple / Google entries.
          AppButton(
            label: l10n.authContinueWithEmail,
            size: AppButtonSize.large,
            variant: AppButtonVariant.secondary,
            onPressed: _busy
                ? null
                : () => context.pushNamed(AppRoute.signUp.name),
          ).animate().fadeIn(delay: 540.ms).slideY(begin: 0.2, end: 0),
          const SizedBox(height: 6),
          Center(
            child: TextButton(
              onPressed: _busy
                  ? null
                  : () => context.pushNamed(AppRoute.signIn.name),
              child: Text(l10n.authHaveAccount),
            ),
          ).animate().fadeIn(delay: 620.ms),
          const SizedBox(height: AppSpacing.md),
          // Apple expects easy access to Terms + Privacy from any
          // pre-auth surface. Keep the legal sentence above the two
          // tappable links.
          Text(
            l10n.authTerms,
            textAlign: TextAlign.center,
            style: AppTypography.caption,
          ),
          const SizedBox(height: 4),
          // Wrap (not Row) so the two links flow to a second line on
          // narrow iPhones (SE / mini) instead of being truncated. No
          // middot separator — the spacing alone carries the visual
          // beat and never ends up orphaned on its own wrap-line.
          Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 14,
            runSpacing: 0,
            children: [
              _AuthLegalLink(
                label: l10n.settingsTerms,
                onPressed: () =>
                    context.pushNamed(AppRoute.settingsTerms.name),
              ),
              _AuthLegalLink(
                label: l10n.settingsPrivacyPolicy,
                onPressed: () =>
                    context.pushNamed(AppRoute.settingsPrivacyPolicy.name),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
        ],
      ),
    );
  }
}

/// Minimalist legal link used in the auth footer — quiet underline
/// affordance (Apple-style), no fill, tight padding so the [Wrap]
/// parent can pack two side-by-side on wide phones and stack them
/// vertically on the smallest iPhones (SE).
class _AuthLegalLink extends StatelessWidget {
  const _AuthLegalLink({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        minimumSize: const Size(48, 36),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        foregroundColor: AppColors.textSecondary,
        overlayColor: AppColors.brandPink.withValues(alpha: 0.10),
      ),
      child: Text(
        label,
        style: AppTypography.caption.copyWith(
          color: AppColors.textSecondary,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
          decoration: TextDecoration.underline,
          decorationColor: AppColors.textTertiary,
          decorationThickness: 0.8,
        ),
      ),
    );
  }
}
