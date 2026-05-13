import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../core/config/app_config.dart';
import '../../../shared/widgets/app_logo.dart';
import '../../../shared/widgets/app_scaffold.dart';

/// Shown while the router is computing the first redirect (auth + onboarding
/// providers warming up). It is not responsible for any navigation — that
/// belongs to the GoRouter `redirect` logic.
class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const AppLogo(fontSize: 44)
                .animate()
                .fadeIn(duration: 600.ms)
                .scale(begin: const Offset(0.96, 0.96), end: const Offset(1, 1)),
            const SizedBox(height: AppSpacing.md),
            Text(
              AppConfig.tagline,
              style: AppTypography.body.copyWith(
                color: AppColors.textSecondary,
              ),
            ).animate().fadeIn(delay: 400.ms, duration: 600.ms),
            const SizedBox(height: AppSpacing.xxl),
            const SizedBox(
              height: 28,
              width: 28,
              child: CircularProgressIndicator(
                strokeWidth: 2.2,
                valueColor: AlwaysStoppedAnimation(AppColors.brandPink),
              ),
            ).animate().fadeIn(delay: 700.ms),
          ],
        ),
      ),
    );
  }
}
