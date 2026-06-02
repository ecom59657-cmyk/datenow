import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/app_logo.dart';
import '../../../shared/widgets/app_scaffold.dart';

/// Premium open animation, shown while the router warms up auth + session.
///
/// It owns NO navigation — the GoRouter `redirect` decides when to leave,
/// and the `splashGateProvider` guarantees this screen stays visible for a
/// minimum elegant window (≈1.1 s) so the animation is actually seen. The
/// dark `#0A0A0F` canvas matches the native launch screen, so there is no
/// flash on entry and the exit is a soft cross-fade (see the route's
/// `CustomTransitionPage`).
class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AppScaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Wordmark sitting over a soft brand halo that breathes — the
            // halo is purely decorative so it ignores pointers and never
            // affects layout (it's in a non-expanding Stack with the logo).
            Stack(
              alignment: Alignment.center,
              children: [
                const _LogoHalo(),
                const AppLogo(fontSize: 46)
                    .animate()
                    .fadeIn(duration: 700.ms, curve: Curves.easeOut)
                    .scale(
                      begin: const Offset(0.92, 0.92),
                      end: const Offset(1, 1),
                      duration: 700.ms,
                      curve: Curves.easeOutCubic,
                    ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              l10n.appTagline,
              style: AppTypography.body.copyWith(
                color: AppColors.textSecondary,
              ),
            ).animate().fadeIn(delay: 450.ms, duration: 600.ms),
            const SizedBox(height: AppSpacing.xxl),
            const SizedBox(
              height: 26,
              width: 26,
              child: CircularProgressIndicator(
                strokeWidth: 2.2,
                valueColor: AlwaysStoppedAnimation(AppColors.brandPink),
              ),
            ).animate().fadeIn(delay: 800.ms, duration: 500.ms),
          ],
        ),
      ),
    );
  }
}

/// Soft radial brand glow behind the wordmark. Fades in with the logo, then
/// breathes slowly (opacity only) for a subtle premium pulse. Decorative —
/// wrapped in [IgnorePointer] and given a fixed size so it never shifts the
/// centred column.
class _LogoHalo extends StatelessWidget {
  const _LogoHalo();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: 260,
        height: 260,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [
              AppColors.brandPink.withValues(alpha: 0.22),
              AppColors.brandViolet.withValues(alpha: 0.10),
              AppColors.brandViolet.withValues(alpha: 0),
            ],
            stops: const [0.0, 0.55, 1.0],
          ),
        ),
      )
          .animate(onPlay: (c) => c.repeat(reverse: true))
          .fadeIn(duration: 700.ms, curve: Curves.easeOut)
          .then()
          .fade(begin: 1, end: 0.6, duration: 1600.ms, curve: Curves.easeInOut),
    );
  }
}
