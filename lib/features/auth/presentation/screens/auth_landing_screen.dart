import 'package:flutter/gestures.dart';
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

  /// Tap recognizers for the inline legal links in the Text.rich footer.
  /// They MUST live in the State (not be created in build) so they survive
  /// rebuilds and get disposed cleanly when the screen unmounts.
  late final TapGestureRecognizer _termsRecognizer;
  late final TapGestureRecognizer _privacyRecognizer;

  @override
  void initState() {
    super.initState();
    _termsRecognizer = TapGestureRecognizer()
      ..onTap = () {
        if (!mounted) return;
        context.pushNamed(AppRoute.settingsTerms.name);
      };
    _privacyRecognizer = TapGestureRecognizer()
      ..onTap = () {
        if (!mounted) return;
        context.pushNamed(AppRoute.settingsPrivacyPolicy.name);
      };
  }

  @override
  void dispose() {
    _termsRecognizer.dispose();
    _privacyRecognizer.dispose();
    super.dispose();
  }

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
          // Returning-user reassurance — purely informational. NOT a
          // TextButton (used to be) because "Continuer avec un email"
          // already covers the signin path, and OAuth providers
          // (Apple, Google) handle sign-up vs sign-in transparently.
          // Rendering this as a Center>TextButton made it look like a
          // 4th call-to-action and confused users into thinking they
          // needed a separate "I already have an account" flow.
          //
          // No GestureDetector / InkWell / underline — it must read as
          // copy, not as a tap target. `IgnorePointer` defensively
          // forbids any future hit-testing on this block in case a
          // parent ever tried to wrap it.
          const SizedBox(height: AppSpacing.md),
          IgnorePointer(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              child: Text.rich(
                TextSpan(
                  style: AppTypography.caption.copyWith(
                    color: AppColors.textSecondary,
                    height: 1.45,
                    fontSize: 12,
                  ),
                  children: [
                    TextSpan(
                      text: l10n.authReturningUserPrefix,
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const TextSpan(text: ' '),
                    TextSpan(text: l10n.authReturningUserBody),
                  ],
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ).animate().fadeIn(delay: 620.ms),
          // Extra air between the "Déjà inscrit ?" reassurance and the
          // legal footer — the spec asks for the footer to feel like a
          // true secondary surface, not stacked against the line above.
          const SizedBox(height: AppSpacing.lg),
          // Premium minimalist legal footer (Apple / Bumble / Revolut /
          // Notion). One Text.rich :
          //   • intro line — 11 pt w400, white α=0.45 (whisper-quiet) ;
          //   • link line — 12 pt w500, white α=0.72 ;
          //   • " et " / " and " between the two links keeps the intro
          //     style, so the link labels read as a single coherent
          //     phrase instead of a button list.
          // No background, no border, no underline — pure typography.
          // The inline TapGestureRecognizers belong to the State (init/
          // dispose) so they survive rebuilds and never leak.
          //
          // On iPhone SE the line wraps naturally between the two link
          // labels — the recognizers stay attached to the words, so
          // tapping the wrapped label still hits the right route.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: Text.rich(
              TextSpan(
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w400,
                  color: Colors.white.withValues(alpha: 0.45),
                  height: 1.55,
                  letterSpacing: 0.05,
                ),
                children: [
                  TextSpan(text: l10n.authLegalIntro),
                  const TextSpan(text: '\n'),
                  TextSpan(
                    text: l10n.settingsTerms,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: Colors.white.withValues(alpha: 0.72),
                    ),
                    recognizer: _termsRecognizer,
                  ),
                  TextSpan(text: l10n.authLegalConjunction),
                  TextSpan(
                    text: l10n.settingsPrivacyPolicy,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: Colors.white.withValues(alpha: 0.72),
                    ),
                    recognizer: _privacyRecognizer,
                  ),
                ],
              ),
              textAlign: TextAlign.center,
            ),
          ).animate().fadeIn(delay: 700.ms),
          const SizedBox(height: AppSpacing.md),
        ],
      ),
    );
  }
}

