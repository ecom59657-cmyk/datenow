import 'package:flutter/material.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_spacing.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../../../shared/widgets/glass_card.dart';

/// A long-form legal screen — title at the top, "last updated …" line, then
/// a list of `(heading, body)` sections in a glass card. Used by both
/// Terms of Use and Privacy Policy.
class LegalDocumentScreen extends StatelessWidget {
  const LegalDocumentScreen({
    super.key,
    required this.title,
    required this.lastUpdated,
    required this.sections,
  });

  final String title;
  final String lastUpdated;
  final List<(String, String)> sections;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AppScaffold(
      appBar: AppBar(
        title: Text(title),
        leading: const BackButton(),
      ),
      body: ListView(
        padding: const EdgeInsets.only(top: AppSpacing.md, bottom: 64),
        children: [
          Text(
            l10n.legalLastUpdated(lastUpdated),
            style: AppTypography.caption.copyWith(
              color: AppColors.textTertiary,
              letterSpacing: 0.3,
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          GlassCard(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final (i, section) in sections.indexed) ...[
                  Text(section.$1, style: AppTypography.bodyStrong),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    section.$2,
                    style: AppTypography.body.copyWith(
                      color: AppColors.textSecondary,
                      height: 1.55,
                    ),
                  ),
                  if (i < sections.length - 1)
                    const SizedBox(height: AppSpacing.lg),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
