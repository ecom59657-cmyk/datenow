import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import 'grain_overlay.dart';

/// The app's ground: flat ivory with a fine grain over it.
///
/// It used to be a near-black canvas with two saturated brand orbs. The
/// orbs are gone — on paper, a coloured glow reads as a printing accident,
/// not as depth. What remains is a single very quiet [AppColors.tint] halo
/// behind the top of the screen, so hero areas breathe without introducing
/// a second colour.
///
/// The name is kept (rather than renamed to something like `AppBackground`)
/// because it is referenced from the auth, splash and onboarding trees; the
/// gradient it now draws is simply almost invisible.
class GradientBackground extends StatelessWidget {
  const GradientBackground({
    super.key,
    required this.child,
    this.intensity = 1.0,
  });

  final Widget child;

  /// 0.0 → flat ivory, 1.0 → the (still discreet) tint halo. Same knob as
  /// before so existing call sites keep working.
  final double intensity;

  @override
  Widget build(BuildContext context) {
    final i = intensity.clamp(0.0, 1.0);
    return DecoratedBox(
      decoration: const BoxDecoration(color: AppColors.ivory),
      child: Stack(
        children: [
          if (i > 0)
            Positioned(
              top: -220,
              left: -80,
              right: -80,
              child: IgnorePointer(
                child: Container(
                  height: 520,
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: Alignment.center,
                      radius: 0.75,
                      colors: [
                        AppColors.tint.withValues(alpha: 0.85 * i),
                        AppColors.ivory.withValues(alpha: 0),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          const Positioned.fill(child: GrainOverlay()),
          Positioned.fill(child: child),
        ],
      ),
    );
  }
}
