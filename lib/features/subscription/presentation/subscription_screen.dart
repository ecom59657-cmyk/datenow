import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/app_button.dart';
import '../../../shared/widgets/app_scaffold.dart';
import '../../../shared/widgets/glass_card.dart';
import 'providers/subscription_provider.dart';

/// Premium subscription screen. Sells the experience (real dates,
/// feeling, less superficiality) rather than a feature checklist.
/// Stripe is intentionally not wired yet — the CTA flips a server-side
/// mock flag via [SubscriptionRepository.upgradeToPremium] so the rest
/// of the app (badges, quota gates) behaves like a real upgrade.
class SubscriptionScreen extends ConsumerStatefulWidget {
  const SubscriptionScreen({super.key});

  @override
  ConsumerState<SubscriptionScreen> createState() =>
      _SubscriptionScreenState();
}

class _SubscriptionScreenState extends ConsumerState<SubscriptionScreen> {
  /// Coming-soon teaser sheet — surfaced when the user taps the
  /// "Bientôt disponible" CTA. No paywall, no Stripe, no upgrade
  /// RPC : the entire purchase path is dormant until DateNow
  /// Premium ships. The sheet keeps the moment feeling
  /// considered rather than broken — same orb-gradient visual
  /// language as the photo-required and identity-required sheets.
  ///
  /// TODO(i18n) : strings hardcoded FR. Localise when the wording
  /// is signed off by product.
  Future<void> _showComingSoonSheet(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => SafeArea(
        top: false,
        minimum: const EdgeInsets.only(bottom: AppSpacing.sm),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.lg,
            AppSpacing.lg,
            AppSpacing.sm,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                width: 80,
                height: 80,
                alignment: Alignment.center,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: AppColors.signatureGradient,
                ),
                child: const Icon(
                  Icons.auto_awesome_rounded,
                  color: Colors.white,
                  size: 36,
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              Text(
                'DateNow Premium arrive bientôt ✨',
                textAlign: TextAlign.center,
                style: AppTypography.h2,
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                'Nous préparons actuellement l\'expérience premium. '
                'Tu seras parmi les premiers à en profiter.',
                textAlign: TextAlign.center,
                style: AppTypography.body
                    .copyWith(color: AppColors.textSecondary),
              ),
              const SizedBox(height: AppSpacing.lg),
              AppButton(
                label: 'Compris',
                variant: AppButtonVariant.secondary,
                onPressed: () => Navigator.of(sheetContext).pop(),
              ),
              const SizedBox(height: AppSpacing.sm),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final stateAsync = ref.watch(subscriptionStateProvider);
    final isPremium = stateAsync.asData?.value.isPremium ?? false;

    final benefits = <(IconData, String, String)>[
      (
        Icons.all_inclusive_rounded,
        l10n.subscriptionBenefit1Title,
        l10n.subscriptionBenefit1Body,
      ),
      (
        Icons.bolt_rounded,
        l10n.subscriptionBenefit2Title,
        l10n.subscriptionBenefit2Body,
      ),
      (
        Icons.favorite_rounded,
        l10n.subscriptionBenefit3Title,
        l10n.subscriptionBenefit3Body,
      ),
      (
        Icons.history_rounded,
        l10n.subscriptionBenefit4Title,
        l10n.subscriptionBenefit4Body,
      ),
      (
        Icons.workspace_premium_rounded,
        l10n.subscriptionBenefit5Title,
        l10n.subscriptionBenefit5Body,
      ),
    ];

    return AppScaffold(
      appBar: AppBar(
        title: Text(l10n.subscriptionTitle),
        leading: const BackButton(),
      ),
      body: ListView(
        padding: const EdgeInsets.only(
          top: AppSpacing.lg,
          bottom: 96,
        ),
        children: [
          Center(
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: 7,
              ),
              decoration: const BoxDecoration(
                gradient: AppColors.signatureGradient,
                borderRadius: AppRadius.brPill,
              ),
              child: Text(
                l10n.subscriptionBrand,
                style: AppTypography.caption.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.1,
                ),
              ),
            ),
          ).animate().fadeIn(duration: 320.ms).scale(
                begin: const Offset(0.9, 0.9),
                end: const Offset(1, 1),
                duration: 360.ms,
                curve: Curves.easeOutBack,
              ),
          const SizedBox(height: AppSpacing.lg),
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: Text(
              l10n.subscriptionSubtitle,
              textAlign: TextAlign.center,
              style: AppTypography.h3.copyWith(
                color: AppColors.textSecondary,
                height: 1.35,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.xl),
          _PriceHero(
            amount: l10n.subscriptionPriceAmount,
            period: l10n.subscriptionPricePeriod,
            footer: l10n.subscriptionPriceFooter,
            isPremium: isPremium,
            premiumBody: l10n.subscriptionPremiumBody,
          ),
          const SizedBox(height: AppSpacing.xl),
          for (final (i, b) in benefits.indexed) ...[
            _BenefitTile(icon: b.$1, title: b.$2, body: b.$3)
                .animate(delay: (40 * i).ms)
                .fadeIn(duration: 320.ms)
                .moveY(begin: 8, end: 0, duration: 320.ms),
            if (i < benefits.length - 1)
              const SizedBox(height: AppSpacing.sm),
          ],
          const SizedBox(height: AppSpacing.xl),
          isPremium
              ? AppButton(
                  label: l10n.subscriptionManageCta,
                  icon: Icons.workspace_premium_rounded,
                  size: AppButtonSize.large,
                  variant: AppButtonVariant.secondary,
                  onPressed: () {},
                )
              // Premium purchase flow is intentionally dormant.
              // The CTA looks premium (brand-pink halo preserved)
              // but communicates "coming soon" via the clock icon
              // + the bottom-sheet teaser below.
              : _PremiumComingSoonCta(
                  onPressed: () => _showComingSoonSheet(context),
                ),
        ],
      ),
    );
  }
}

/// Centered price block — biggest visual weight on the page. Carries
/// the brand glow so the eye lands here before the benefits list.
class _PriceHero extends StatelessWidget {
  const _PriceHero({
    required this.amount,
    required this.period,
    required this.footer,
    required this.isPremium,
    required this.premiumBody,
  });

  final String amount;
  final String period;
  final String footer;
  final bool isPremium;
  final String premiumBody;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.xl,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (isPremium) ...[
            const Icon(
              Icons.workspace_premium_rounded,
              color: AppColors.bordeaux,
              size: 44,
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              premiumBody,
              textAlign: TextAlign.center,
              style: AppTypography.bodyLarge.copyWith(
                color: AppColors.textSecondary,
              ),
            ),
          ] else ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                ShaderMask(
                  shaderCallback: (rect) =>
                      AppColors.signatureGradient.createShader(rect),
                  child: Text(
                    amount,
                    style: AppTypography.display.copyWith(
                      color: Colors.white,
                      fontSize: 56,
                      letterSpacing: -1,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    period,
                    style: AppTypography.bodyLarge.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              footer,
              textAlign: TextAlign.center,
              style: AppTypography.caption.copyWith(
                color: AppColors.textTertiary,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// One bullet of the benefits section — gradient icon pill on the
/// left, title in bodyStrong, body in muted textSecondary. Keeps the
/// list scannable on iPhone SE while staying premium.
class _BenefitTile extends StatelessWidget {
  const _BenefitTile({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: const BoxDecoration(
              gradient: AppColors.signatureGradient,
              borderRadius: AppRadius.brSm,
            ),
            child: Icon(icon, color: Colors.white, size: 20),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: AppTypography.bodyStrong,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  body,
                  style: AppTypography.body.copyWith(
                    color: AppColors.textSecondary,
                    height: 1.35,
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

/// "Coming soon" Premium CTA — same gradient + brand-pink glow halo
/// as the (now-removed) `_PremiumCtaButton`, so the visual weight on
/// the subscription page stays intentional. The clock icon
/// (`schedule_rounded`) is the only signal that the feature is not
/// yet shipped — pressing the button opens a teaser sheet instead
/// of triggering the dormant upgrade RPC.
///
/// TODO(i18n) : the label is hardcoded FR until product signs off
/// the wording.
class _PremiumComingSoonCta extends StatelessWidget {
  const _PremiumComingSoonCta({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        borderRadius: AppRadius.brSm,
      ),
      child: AppButton(
        label: 'Bientôt disponible',
        icon: Icons.schedule_rounded,
        size: AppButtonSize.large,
        onPressed: onPressed,
      ),
    );
  }
}
