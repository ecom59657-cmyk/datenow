import 'package:flutter/material.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_spacing.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../l10n/app_localizations.dart';

/// Confirmation dialog used by sign out + delete account. Wraps the
/// destructive call site in a single styled prompt so the look stays
/// consistent.
///
/// Returns `true` if the user confirmed.
Future<bool> showDestructiveConfirm({
  required BuildContext context,
  required String title,
  required String body,
  required String confirmLabel,
  bool isDangerous = true,
}) async {
  final l10n = AppLocalizations.of(context);
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) {
      return AlertDialog(
        backgroundColor: AppColors.surfaceElevated,
        shape: const RoundedRectangleBorder(borderRadius: AppRadius.brLg),
        title: Text(title, style: AppTypography.h3),
        content: Text(
          body,
          style: AppTypography.body.copyWith(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(
              l10n.commonCancel,
              style: AppTypography.button.copyWith(
                color: AppColors.textSecondary,
              ),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
              confirmLabel,
              style: AppTypography.button.copyWith(
                color: isDangerous ? AppColors.error : AppColors.bordeaux,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      );
    },
  );
  return result ?? false;
}
