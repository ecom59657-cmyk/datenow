import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/router/app_routes.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_spacing.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../../shared/widgets/app_button.dart';

/// Premium bottom-sheet shown when a male user hits the daily 5-match cap.
/// Women never see this — their cap is `null`.
Future<void> showQuotaLimitSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => const _QuotaLimitSheet(),
  );
}

class _QuotaLimitSheet extends StatelessWidget {
  const _QuotaLimitSheet();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

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
              l10n.quotaLimitBody,
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
              onPressed: () {
                Navigator.of(context).pop();
                context.pushNamed(AppRoute.settingsSubscription.name);
              },
            ),
            const SizedBox(height: AppSpacing.sm),
            AppButton(
              label: l10n.quotaComeBackCta,
              variant: AppButtonVariant.ghost,
              onPressed: () => Navigator.of(context).pop(),
            ),
            const SizedBox(height: AppSpacing.xs),
          ],
        ),
      ),
    );
  }
}
