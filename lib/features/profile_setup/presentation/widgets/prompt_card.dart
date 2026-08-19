import 'package:flutter/material.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_spacing.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../l10n/app_localizations.dart';
import '../../domain/prompt.dart';
import '../../domain/prompt_answer.dart';

/// How an answered prompt looks, everywhere it is read.
///
/// Sand ground, question as a clay overline, answer in the serif. It is
/// drawn on the Discover card, on your own profile and at rest inside the
/// editor — three copies of the same recipe would drift, and the whole
/// point is that what you type already looks like what the other person
/// will read.
class PromptCard extends StatelessWidget {
  const PromptCard({
    super.key,
    required this.answer,
    this.trailing,
    this.onTap,
    this.maxLines = 3,
  });

  final PromptAnswer answer;
  final Widget? trailing;
  final VoidCallback? onTap;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    final content = Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: const BoxDecoration(
        color: AppColors.sand,
        borderRadius: AppRadius.brLg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  answer.question.label(l10n).toUpperCase(),
                  style: AppTypography.overline.copyWith(
                    color: AppColors.clay,
                    fontSize: 10,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (trailing != null) trailing!,
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            answer.answer,
            style: AppTypography.h3.copyWith(fontSize: 17),
            maxLines: maxLines,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );

    if (onTap == null) return content;
    return InkWell(
      onTap: onTap,
      borderRadius: AppRadius.brLg,
      child: content,
    );
  }
}
