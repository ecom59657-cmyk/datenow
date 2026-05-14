import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/app_routes.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../core/utils/extensions.dart';
import '../../../core/utils/logger.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/app_scaffold.dart';
import '../../../shared/widgets/glass_card.dart';
import '../../auth/presentation/providers/auth_provider.dart';
import '../../profile_setup/presentation/providers/profile_provider.dart';
import '../../quota/data/quota_repository.dart';
import '../../quota/presentation/widgets/quota_limit_sheet.dart';
import 'widgets/home_header.dart';
import 'widgets/match_cta_card.dart';
import 'widgets/stat_tile.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
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
            onPressed: () => _onFindDate(context, ref),
          ),
          const SizedBox(height: AppSpacing.xl),
          Text(l10n.tonightOnDatenow, style: AppTypography.h3),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              Expanded(
                child: StatTile(
                  icon: Icons.people_alt_rounded,
                  value: '1.2k',
                  label: l10n.peopleOnline,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: StatTile(
                  icon: Icons.bolt_rounded,
                  value: '38s',
                  label: l10n.avgMatchTime,
                  accent: AppColors.brandViolet,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          StatTile(
            icon: Icons.favorite_rounded,
            value: l10n.newLikesValue(4),
            label: l10n.newLikesLabel,
          ),
          const SizedBox(height: AppSpacing.xl),
          Text(l10n.howItWorks, style: AppTypography.h3),
          const SizedBox(height: AppSpacing.sm),
          _HowItWorksCard(
            steps: [l10n.howItWorks1, l10n.howItWorks2, l10n.howItWorks3],
          ),
        ],
      ),
    );
  }

  static const _log = AppLogger('FindDate');

  /// Entry point for the "Find a date now" CTA.
  ///
  /// The chain is intentionally noisy in the console so a future
  /// "the button does nothing" report is debuggable from the logs alone:
  ///
  ///   Find date clicked
  ///   User authenticated: `uid`
  ///   Profile complete for `uid`
  ///   Quota OK: used=`n` cap=`n|null`     (or "Quota check failed")
  ///   Matching started → navigating to /matching
  ///
  /// Every failure path also surfaces a localized [SnackBar] so the user
  /// gets feedback instead of an apparently dead tap.
  Future<void> _onFindDate(BuildContext context, WidgetRef ref) async {
    _log.info('Find date clicked');
    final l10n = AppLocalizations.of(context);

    // 1. Auth — the user must be signed in. Router redirects should keep
    //    us out of /home without it, but we don't trust that contract.
    final user = ref.read(currentUserProvider);
    if (user == null) {
      _log.warn('No authenticated user — aborting.');
      if (context.mounted) {
        context.showSnack(l10n.findDateNotAuthenticated);
      }
      return;
    }
    _log.info('User authenticated: ${user.id}');

    // 2. Profile must be complete. Same router-guarantee caveat applies.
    final profile = ref.read(currentProfileProvider).asData?.value;
    if (profile == null || !profile.isComplete) {
      _log.warn(
        'Profile not ready (loaded=${profile != null}, '
        'complete=${profile?.isComplete ?? false}) — aborting.',
      );
      if (context.mounted) {
        context.showSnack(l10n.findDateProfileIncomplete);
      }
      return;
    }
    _log.info('Profile complete for ${user.id}');

    // 3. Quota — wrapped: a broken quota backend should NOT block the
    //    button. We log and proceed in that case.
    try {
      final status =
          await ref.read(quotaRepositoryProvider).currentStatus(profile);
      _log.info(
        'Quota OK: used=${status.usedToday} cap=${status.cap ?? "∞"}',
      );
      if (status.isExhausted) {
        _log.info('Quota exhausted — showing limit sheet.');
        if (!context.mounted) return;
        await showQuotaLimitSheet(context);
        return;
      }
    } catch (e, st) {
      _log.error('Quota check failed (continuing anyway): $e', e, st);
    }

    // 4. Navigate to the matching screen. The matching screen owns the
    //    "find candidate → start call session → open call screen" chain.
    if (!context.mounted) return;
    _log.info('Matching started → navigating to /matching');
    try {
      context.pushNamed(AppRoute.matching.name);
    } catch (e, st) {
      _log.error('Navigation to /matching failed: $e', e, st);
      if (!context.mounted) return;
      context.showSnack(l10n.findDateError);
    }
  }
}

class _HowItWorksCard extends StatelessWidget {
  const _HowItWorksCard({required this.steps});

  final List<String> steps;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (i, step) in steps.indexed) ...[
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
                    '${i + 1}',
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
                    child: Text(step, style: AppTypography.bodyLarge),
                  ),
                ),
              ],
            ),
            if (i < steps.length - 1) const SizedBox(height: AppSpacing.md),
          ],
        ],
      ),
    );
  }
}
