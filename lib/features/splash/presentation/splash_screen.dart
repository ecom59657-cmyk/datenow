import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../shared/widgets/app_logo.dart';

/// Open animation, shown while the router warms up auth + session.
///
/// It owns NO navigation — the GoRouter `redirect` decides when to leave,
/// and `splashGateProvider` holds the screen for a minimum window (≈1.1 s)
/// so the animation is actually seen.
///
/// Bordeaux, alone in the app: everywhere else the ground is ivory and dark
/// is reserved for the call. Here it earns its place — the wordmark and the
/// ivory-grounded icon need something to stand against, and an app opening
/// on its own colour states what it is before a single screen loads. The
/// native launch screen carries the same bordeaux, so the ground never
/// changes between the two.
class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      // Light glyphs: the rest of the app runs dark-on-ivory, and this is
      // the one screen where that would be unreadable.
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
        systemNavigationBarColor: AppColors.bordeaux,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
      child: Scaffold(
        // Flat AppColors.bordeaux — the exact colour of the Home hero card,
        // not its gradient. The card runs signatureGradient across 330 px;
        // stretched over a whole screen the same recipe puts its dark end
        // right where the logo sits, so the two surfaces read as different
        // colours. Matching the card means taking the colour, not the
        // recipe.
        backgroundColor: AppColors.bordeaux,
        body: DecoratedBox(
          decoration: const BoxDecoration(color: AppColors.bordeaux),
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Stack(
                  alignment: Alignment.center,
                  children: [
                    const _LogoHalo(),
                    const AppLogo(
                      fontSize: 46,
                      showMark: true,
                      onDark: true,
                    )
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
                // No tagline. It faded in at 450 ms on a screen that is
                // gone in about a second — nobody finished reading it, and
                // a line you cannot read is worse than no line: it makes
                // the opening feel busy.
                const SizedBox(height: AppSpacing.xxl),
                const SizedBox(
                  height: 26,
                  width: 26,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.2,
                    valueColor: AlwaysStoppedAnimation(AppColors.paper),
                  ),
                ).animate().fadeIn(delay: 800.ms, duration: 500.ms),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Soft light behind the wordmark, so the centre of the screen lifts off
/// the bordeaux instead of sitting flat on it. Decorative: it ignores
/// pointers and has a fixed size, so it never shifts the centred column.
class _LogoHalo extends StatelessWidget {
  const _LogoHalo();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: 280,
        height: 280,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [
              AppColors.paper.withValues(alpha: 0.14),
              AppColors.paper.withValues(alpha: 0.05),
              AppColors.paper.withValues(alpha: 0),
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
