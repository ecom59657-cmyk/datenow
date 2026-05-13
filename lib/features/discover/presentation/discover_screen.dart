import 'package:flutter/material.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../shared/widgets/app_scaffold.dart';
import '../../../shared/widgets/glass_card.dart';

class DiscoverScreen extends StatelessWidget {
  const DiscoverScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      body: ListView(
        padding: const EdgeInsets.only(bottom: 120),
        physics: const BouncingScrollPhysics(),
        children: [
          const SizedBox(height: AppSpacing.md),
          Text('Discover', style: AppTypography.h1),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'Browse profiles you crossed paths with on a live date.',
            style: AppTypography.body.copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: AppSpacing.xl),
          GlassCard(
            padding: const EdgeInsets.all(AppSpacing.xl),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(AppSpacing.sm),
                  decoration: BoxDecoration(
                    color: AppColors.violetSoft,
                    borderRadius: AppRadius.brSm,
                  ),
                  child: const Icon(
                    Icons.travel_explore_rounded,
                    color: AppColors.brandViolet,
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                Text('No profiles yet', style: AppTypography.h3),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  'Profiles you swap with after a live date will show up here. '
                  'Go to Home and tap "Find a date now" to get started.',
                  style: AppTypography.body.copyWith(
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
