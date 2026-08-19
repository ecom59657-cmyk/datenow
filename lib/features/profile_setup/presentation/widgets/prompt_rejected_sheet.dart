import 'package:flutter/material.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_spacing.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../../shared/widgets/app_button.dart';
import '../../domain/prompt_moderation.dart';

/// Shown when the moderation filter refuses an answer.
///
/// A sheet rather than a snackbar: a snackbar slides away on its own, and
/// this is the one message the user has to act on before anything is saved.
/// It also has to explain itself — someone who typed their Instagram handle
/// is not misbehaving, they are doing the obvious thing, and being told
/// "refused" without a reason is how people conclude the app is broken.
///
/// Same shape as the quota sheet, so a refusal reads as part of the app and
/// not as an error page bolted on.
Future<void> showPromptRejectedSheet(
  BuildContext context,
  PromptRejection reason,
) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => _PromptRejectedSheet(reason: reason),
  );
}

class _PromptRejectedSheet extends StatelessWidget {
  const _PromptRejectedSheet({required this.reason});

  final PromptRejection reason;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final isContact = reason == PromptRejection.contact;

    return SafeArea(
      child: Container(
        margin: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: AppColors.paper,
          borderRadius: AppRadius.brXl,
          border: Border.all(color: AppColors.line),
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
                  // Amber, not error red: nothing has gone wrong, an answer
                  // simply cannot be published as written.
                  color: AppColors.amberTint,
                ),
                child: Icon(
                  isContact
                      ? Icons.alternate_email_rounded
                      : Icons.report_gmailerrorred_rounded,
                  color: AppColors.amber,
                  size: 28,
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            Text(
              isContact
                  ? l10n.promptRejectedTitleContact
                  : l10n.promptRejectedTitleTerm,
              textAlign: TextAlign.center,
              style: AppTypography.h2,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              isContact
                  ? l10n.promptRejectedContact
                  : l10n.promptRejectedTerm,
              textAlign: TextAlign.center,
              style: AppTypography.body,
            ),
            const SizedBox(height: AppSpacing.xl),
            AppButton(
              label: l10n.promptRejectedCta,
              size: AppButtonSize.large,
              onPressed: () => Navigator.of(context).pop(),
            ),
            const SizedBox(height: AppSpacing.xs),
          ],
        ),
      ),
    );
  }
}
