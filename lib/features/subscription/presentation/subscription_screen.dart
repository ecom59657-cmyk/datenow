import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../core/utils/extensions.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/app_button.dart';
import '../../../shared/widgets/app_scaffold.dart';
import '../../../shared/widgets/glass_card.dart';
import '../../profile_setup/presentation/providers/profile_provider.dart';
import '../data/subscription_repository.dart';
import '../domain/subscription_state.dart';
import 'providers/subscription_provider.dart';

class SubscriptionScreen extends ConsumerStatefulWidget {
  const SubscriptionScreen({super.key});

  @override
  ConsumerState<SubscriptionScreen> createState() =>
      _SubscriptionScreenState();
}

class _SubscriptionScreenState extends ConsumerState<SubscriptionScreen> {
  bool _upgrading = false;

  Future<void> _upgrade() async {
    final profile = ref.read(currentProfileProvider).asData?.value;
    if (profile == null) return;
    setState(() => _upgrading = true);
    await ref
        .read(subscriptionRepositoryProvider)
        .upgradeToPremium(profile.userId);
    if (!mounted) return;
    setState(() => _upgrading = false);
    final l10n = AppLocalizations.of(context);
    context.showSnack(l10n.subscriptionUpgradedSnack);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final stateAsync = ref.watch(subscriptionStateProvider);
    final repo = ref.watch(subscriptionRepositoryProvider);

    return AppScaffold(
      appBar: AppBar(
        title: Text(l10n.subscriptionTitle),
        leading: const BackButton(),
      ),
      body: ListView(
        padding: const EdgeInsets.only(top: AppSpacing.md, bottom: 64),
        children: [
          Text(
            l10n.subscriptionSubtitle,
            style:
                AppTypography.body.copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: AppSpacing.lg),
          stateAsync.maybeWhen(
            data: (state) => _TierHero(state: state),
            orElse: () => const _TierHeroSkeleton(),
          ),
          const SizedBox(height: AppSpacing.lg),
          _PerksCard(l10n: l10n),
          const SizedBox(height: AppSpacing.lg),
          if (!repo.isConfigured)
            _DemoNotice(message: l10n.subscriptionMockNotice),
          const SizedBox(height: AppSpacing.lg),
          stateAsync.maybeWhen(
            data: (state) => state.isPremium
                ? AppButton(
                    label: l10n.subscriptionManageCta,
                    icon: Icons.workspace_premium_rounded,
                    size: AppButtonSize.large,
                    variant: AppButtonVariant.secondary,
                    onPressed: () {},
                  )
                : AppButton(
                    label: l10n.subscriptionUpgradeCta,
                    icon: Icons.bolt_rounded,
                    size: AppButtonSize.large,
                    isLoading: _upgrading,
                    onPressed: _upgrading ? null : _upgrade,
                  ),
            orElse: () => const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

class _TierHero extends StatelessWidget {
  const _TierHero({required this.state});

  final SubscriptionState state;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final isPremium = state.isPremium;
    return GlassCard(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.sm,
              vertical: 6,
            ),
            decoration: BoxDecoration(
              gradient: isPremium ? AppColors.brandGradient : null,
              color: isPremium ? null : AppColors.surfaceElevated,
              borderRadius: AppRadius.brPill,
              border: Border.all(
                color: isPremium
                    ? Colors.transparent
                    : AppColors.hairline,
              ),
            ),
            child: Text(
              isPremium
                  ? l10n.subscriptionCurrentPremium
                  : l10n.subscriptionCurrentFree,
              style: AppTypography.caption.copyWith(
                color: isPremium ? Colors.white : AppColors.textSecondary,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.3,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            isPremium
                ? l10n.subscriptionPremiumBody
                : l10n.subscriptionFreeBody,
            style: AppTypography.body.copyWith(color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }
}

class _TierHeroSkeleton extends StatelessWidget {
  const _TierHeroSkeleton();

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: const SizedBox(
        height: 64,
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation(AppColors.brandPink),
            ),
          ),
        ),
      ),
    );
  }
}

class _PerksCard extends StatelessWidget {
  const _PerksCard({required this.l10n});

  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final perks = [
      l10n.subscriptionPerkUnlimited,
      l10n.subscriptionPerkPriority,
      l10n.subscriptionPerkBadge,
      l10n.subscriptionPerkSupport,
    ];
    return GlassCard(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final perk in perks) ...[
            Row(
              children: [
                Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    gradient: AppColors.brandGradient,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(
                    Icons.check_rounded,
                    color: Colors.white,
                    size: 16,
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(child: Text(perk, style: AppTypography.bodyLarge)),
              ],
            ),
            if (perk != perks.last) const SizedBox(height: AppSpacing.sm),
          ],
        ],
      ),
    );
  }
}

class _DemoNotice extends StatelessWidget {
  const _DemoNotice({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.12),
        borderRadius: AppRadius.brSm,
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          const Icon(Icons.info_outline_rounded,
              color: AppColors.warning, size: 18),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              message,
              style: AppTypography.caption.copyWith(
                color: AppColors.warning,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
