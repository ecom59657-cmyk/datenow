import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_spacing.dart';
import '../../../../app/theme/app_typography.dart';

class OnboardingPageData {
  const OnboardingPageData({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;
}

class OnboardingPage extends StatelessWidget {
  const OnboardingPage({super.key, required this.data});

  final OnboardingPageData data;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: AppSpacing.pagePadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Spacer(),
          _IconHero(icon: data.icon)
              .animate()
              .fadeIn(duration: 500.ms)
              .scale(begin: const Offset(0.85, 0.85), end: const Offset(1, 1)),
          const SizedBox(height: AppSpacing.xl),
          Text(data.title, style: AppTypography.h1)
              .animate()
              .fadeIn(delay: 150.ms)
              .slideY(begin: 0.2, end: 0),
          const SizedBox(height: AppSpacing.sm),
          Text(
            data.subtitle,
            style: AppTypography.bodyLarge.copyWith(
              color: AppColors.textSecondary,
              height: 1.5,
            ),
          ).animate().fadeIn(delay: 250.ms).slideY(begin: 0.2, end: 0),
          const Spacer(flex: 2),
        ],
      ),
    );
  }
}

class _IconHero extends StatelessWidget {
  const _IconHero({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 96,
      height: 96,
      decoration: BoxDecoration(
        color: AppColors.tint,
        borderRadius: BorderRadius.circular(28),
      ),
      child: Icon(icon, color: AppColors.bordeaux, size: 40),
    );
  }
}
