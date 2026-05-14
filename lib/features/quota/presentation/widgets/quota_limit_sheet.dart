import 'package:flutter/material.dart';

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
          boxShadow: [
            BoxShadow(
              color: AppColors.brandPink.withValues(alpha: 0.15),
              blurRadius: 40,
              spreadRadius: 4,
            ),
          ],
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
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: AppColors.brandGradient,
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.brandPink.withValues(alpha: 0.35),
                      blurRadius: 24,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.hourglass_top_rounded,
                  color: Colors.white,
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
            AppButton(
              label: l10n.quotaUnlockCta,
              icon: Icons.bolt_rounded,
              size: AppButtonSize.large,
              onPressed: () => Navigator.of(context).pop(),
            ),
            const SizedBox(height: AppSpacing.sm),
            AppButton(
              label: l10n.quotaComeBackCta,
              variant: AppButtonVariant.secondary,
              onPressed: () => Navigator.of(context).pop(),
            ),
            const SizedBox(height: AppSpacing.xs),
          ],
        ),
      ),
    );
  }
}
