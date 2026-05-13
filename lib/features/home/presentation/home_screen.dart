import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/app_routes.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../shared/widgets/app_scaffold.dart';
import '../../../shared/widgets/glass_card.dart';
import '../../auth/presentation/providers/auth_provider.dart';
import 'widgets/home_header.dart';
import 'widgets/match_cta_card.dart';
import 'widgets/stat_tile.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider);

    return AppScaffold(
      body: ListView(
        padding: const EdgeInsets.only(bottom: 120),
        physics: const BouncingScrollPhysics(),
        children: [
          const SizedBox(height: AppSpacing.md),
          HomeHeader(displayName: user?.displayName ?? user?.email)
              .animate()
              .fadeIn(duration: 350.ms),
          const SizedBox(height: AppSpacing.xl),
          MatchCtaCard(
            onPressed: () => context.pushNamed(AppRoute.matching.name),
          ),
          const SizedBox(height: AppSpacing.xl),
          Text(
            'Tonight on DateNow',
            style: AppTypography.h3,
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: const [
              Expanded(
                child: StatTile(
                  icon: Icons.people_alt_rounded,
                  value: '1.2k',
                  label: 'People online near you',
                ),
              ),
              SizedBox(width: AppSpacing.sm),
              Expanded(
                child: StatTile(
                  icon: Icons.bolt_rounded,
                  value: '38s',
                  label: 'Avg. match time',
                  accent: AppColors.brandViolet,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          const StatTile(
            icon: Icons.favorite_rounded,
            value: '4 new',
            label: 'People who liked you back',
          ),
          const SizedBox(height: AppSpacing.xl),
          Text('How it works', style: AppTypography.h3),
          const SizedBox(height: AppSpacing.sm),
          const _HowItWorksCard(),
        ],
      ),
    );
  }
}

class _HowItWorksCard extends StatelessWidget {
  const _HowItWorksCard();

  static const _steps = [
    ('1', 'We match you instantly with someone online & compatible.'),
    ('2', 'A 5-minute audio or video date starts right away.'),
    ('3', 'Keep chatting, swap profiles, or move on. Your call.'),
  ];

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (i, step) in _steps.indexed) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    gradient: AppColors.brandGradient,
                    borderRadius: AppRadius.brSm,
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    step.$1,
                    style: AppTypography.caption.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(step.$2, style: AppTypography.bodyLarge),
                  ),
                ),
              ],
            ),
            if (i < _steps.length - 1) const SizedBox(height: AppSpacing.md),
          ],
        ],
      ),
    );
  }
}
