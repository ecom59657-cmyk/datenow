import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';

/// A full-screen background with subtle radial brand glows on the deep
/// near-black canvas. Used on auth/splash/onboarding screens to give the app
/// its signature premium feel.
class GradientBackground extends StatelessWidget {
  const GradientBackground({
    super.key,
    required this.child,
    this.intensity = 1.0,
  });

  final Widget child;

  /// 0.0 → flat black, 1.0 → full brand glow. Defaults to 1.0.
  final double intensity;

  @override
  Widget build(BuildContext context) {
    final i = intensity.clamp(0.0, 1.0);
    return DecoratedBox(
      decoration: const BoxDecoration(color: AppColors.background),
      child: Stack(
        children: [
          // Top-left pink glow.
          Positioned(
            top: -180,
            left: -120,
            child: _GlowOrb(
              color: AppColors.bordeaux.withValues(alpha: 0.35 * i),
              size: 380,
            ),
          ),
          // Bottom-right violet glow.
          Positioned(
            bottom: -200,
            right: -140,
            child: _GlowOrb(
              color: AppColors.bordeauxLight.withValues(alpha: 0.30 * i),
              size: 420,
            ),
          ),
          Positioned.fill(child: child),
        ],
      ),
    );
  }
}

class _GlowOrb extends StatelessWidget {
  const _GlowOrb({required this.color, required this.size});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [color, color.withValues(alpha: 0)],
          ),
        ),
      ),
    );
  }
}
