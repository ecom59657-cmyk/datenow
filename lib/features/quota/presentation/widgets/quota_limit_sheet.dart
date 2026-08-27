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

  /// The video is over and we are waiting on Google's callback. Separate from
  /// [_busy] only so the button can stop claiming to be loading a video that
  /// has already played.
  bool _verifying = false;

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

  /// Shows the rewarded video and waits for the date it earns.
  ///
  /// The app cannot grant anything any more: since AdMob server-side
  /// verification landed, Google posts a signed callback to the admob-ssv
  /// Edge Function and Postgres writes the row. Closing the video early
  /// produces no callback and so no date — which is the point.
  Future<void> _watchAdForBonus() async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);

    // Read the profile BEFORE the video, not after. Discovering there is
    // nobody to credit once someone has watched thirty seconds is the worst
    // possible order.
    final profile = ref.read(currentProfileProvider).asData?.value;
    if (profile == null) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.quotaAdUnavailable)));
      return;
    }

    setState(() => _busy = true);

    final ads = ref.read(rewardedAdServiceProvider);
    if (!ads.isReady) await ads.preload();

    if (!ads.isReady) {
      if (!mounted) return;
      setState(() => _busy = false);
      messenger.showSnackBar(SnackBar(content: Text(l10n.quotaAdUnavailable)));
      return;
    }

    // The bonus count as it stands now. Google's callback can land while the
    // video is still closing, so without a baseline an early grant would look
    // like no grant at all.
    final repo = ref.read(quotaRepositoryProvider);
    var knownBonus = 0;
    try {
      knownBonus =
          (await repo.currentStatus(profile, isPremium: false)).bonusToday;
    } catch (e) {
      // Unreadable baseline: 0 is the safe assumption — worst case we notice
      // the bonus one poll later than we could have.
    }

    final earned = await ads.showAndAwaitReward(userId: profile.userId);

    var settled = false;
    if (earned) {
      if (mounted) setState(() => _verifying = true);
      settled =
          await repo.awaitRewardedBonus(profile, knownBonusToday: knownBonus);
      ref.invalidate(quotaStatusProvider);
    }

    if (!mounted) return;
    setState(() {
      _busy = false;
      _verifying = false;
    });

    if (settled) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.quotaAdRewarded)));
      Navigator.of(context).pop();
    } else if (earned) {
      // Watched, signed, just not arrived yet. Saying nothing here would read
      // as "you watched that for nothing".
      messenger.showSnackBar(SnackBar(content: Text(l10n.quotaAdPending)));
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
                label: _verifying
                    ? l10n.quotaAdVerifying
                    : _busy
                        ? l10n.quotaAdLoading
                        : l10n.quotaWatchAdCta,
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
