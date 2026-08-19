import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../l10n/app_localizations.dart';
import 'app_button.dart';

/// What a screen shows when a provider fails.
///
/// Eight screens used to render `Text('$e')` — a raw exception, in English,
/// often a `PostgrestException` with a table name in it, and no way out
/// other than killing the app. This gives the user a sentence they can read
/// and a button that actually retries.
class AppErrorState extends StatelessWidget {
  const AppErrorState({
    super.key,
    this.message,
    required this.onRetry,
    this.compact = false,
  });

  /// Defaults to the generic localized load failure.
  final String? message;

  /// Invalidate the failing provider here — not a `setState`, which would
  /// rebuild the same failed AsyncValue.
  final VoidCallback onRetry;

  /// Inline variant for a section inside a scrolling screen, rather than a
  /// full-screen body.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Icon(
          Icons.cloud_off_rounded,
          size: compact ? 24 : 32,
          color: AppColors.ink3,
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          message ?? l10n.errorLoadGeneric,
          textAlign: TextAlign.center,
          style: AppTypography.body,
        ),
        const SizedBox(height: AppSpacing.md),
        AppButton(
          label: l10n.commonRetry,
          icon: Icons.refresh_rounded,
          variant: AppButtonVariant.ghost,
          expanded: false,
          onPressed: onRetry,
        ),
      ],
    );

    return Center(
      child: Padding(
        padding: EdgeInsets.all(compact ? AppSpacing.md : AppSpacing.xl),
        child: content,
      ),
    );
  }
}
