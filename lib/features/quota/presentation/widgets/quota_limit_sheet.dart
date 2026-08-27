import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/router/app_routes.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_spacing.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../../shared/widgets/app_button.dart';
import '../../../ads/presentation/providers/ads_providers.dart';
import '../../../profile_setup/presentation/providers/profile_provider.dart';
import '../../data/quota_repository.dart';
import '../providers/quota_provider.dart';

/// Bottom sheet shown when a capped user runs out of dates for the day.
/// Women never see it — their cap is `null`.
///
/// [dailyCap] is the allowance the user just exhausted — the base cap plus
/// anything an ad or the daily boost added. Passed in rather than read from
/// a provider so the sheet always states the number the caller actually
/// measured against, never a value that drifted between the two reads.
Future<void> showQuotaLimitSheet(
  BuildContext context, {
  required int dailyCap,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => _QuotaLimitSheet(dailyCap: dailyCap),
  );
}

class _QuotaLimitSheet extends ConsumerStatefulWidget {
  const _QuotaLimitSheet({required this.dailyCap});

  final int dailyCap;

  @override
  ConsumerState<_QuotaLimitSheet> createState() => _QuotaLimitSheetState();
}

class _QuotaLimitSheetState extends ConsumerState<_QuotaLimitSheet> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // Fetch while the user reads the sheet: a rewarded video takes a
    // second or two to arrive, and asking after the tap makes the button
    // feel broken.
    if (ref.read(adsEnabledProvider)) {
      ref.read(rewardedAdServiceProvider).preload();
    }
  }

  /// Shows the rewarded video and grants one date — but only on a reward
  /// callback from Google. Dismissing early grants nothing.
  Future<void> _watchAdForBonus() async {
    final l10n = AppLocalizations.of(context);
    setState(() => _busy = true);

    final ads = ref.read(rewardedAdServiceProvider);
    if (!ads.isReady) await ads.preload();

    if (!ads.isReady) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l10n.quotaAdUnavailable)));
      return;
    }

    final earned = await ads.showAndAwaitReward();

    if (earned) {
      final profile = ref.read(currentProfileProvider).asData?.value;
      if (profile != null) {
        await ref.read(quotaRepositoryProvider).grantBonusDate(profile);
        ref.invalidate(quotaStatusProvider);
      }
    }

    if (!mounted) return;
    setState(() => _busy = false);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    if (earned) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.quotaAdRewarded)));
      navigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final adsEnabled = ref.watch(adsEnabledProvider);

    return SafeArea(
      child: Container(
        margin: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: AppColors.surfaceElevated,
          borderRadius: AppRadius.brXl,
          border: Border.all(color: AppColors.hairline),
        ),
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.lg,
          AppSpacing.lg,
          AppSpacing.md,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 64,
                height: 64,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.tint,
                ),
                child: const Icon(
                  Icons.hourglass_top_rounded,
                  color: AppColors.bordeaux,
                  size: 28,
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            Text(
              l10n.quotaLimitTitle,
              textAlign: TextAlign.center,
              style: AppTypography.h2,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              l10n.quotaLimitBody(widget.dailyCap),
              textAlign: TextAlign.center,
              style:
                  AppTypography.body.copyWith(color: AppColors.textSecondary),
            ),
            const SizedBox(height: AppSpacing.xl),
            // "Débloquer plus de dates" used to just close the sheet —
            // a button that names an outcome it does not deliver. It now
            // opens the subscription screen, which is the only place that
            // outcome can come from. The second button was a duplicate of
            // the same pop(), so "Revenir demain" is the honest single
            // action left.
            AppButton(
              label: l10n.quotaUnlockCta,
              icon: Icons.bolt_rounded,
              size: AppButtonSize.large,
              onPressed: _busy
                  ? null
                  : () {
                      Navigator.of(context).pop();
                      context.pushNamed(AppRoute.settingsSubscription.name);
                    },
            ),
            // Free users get a way out that costs nothing but attention.
            // Premium already paid for it, so they never see this.
            if (adsEnabled) ...[
              const SizedBox(height: AppSpacing.sm),
              AppButton(
                label: _busy ? l10n.quotaAdLoading : l10n.quotaWatchAdCta,
                icon: Icons.play_circle_outline_rounded,
                variant: AppButtonVariant.secondary,
                isLoading: _busy,
                onPressed: _busy ? null : _watchAdForBonus,
              ),
            ],
            const SizedBox(height: AppSpacing.sm),
            AppButton(
              label: l10n.quotaComeBackCta,
              variant: AppButtonVariant.ghost,
              onPressed: _busy ? null : () => Navigator.of(context).pop(),
            ),
            const SizedBox(height: AppSpacing.xs),
          ],
        ),
      ),
    );
  }
}
