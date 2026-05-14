import 'package:flutter/material.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../core/utils/extensions.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/app_scaffold.dart';
import '../../../shared/widgets/glass_card.dart';
import 'widgets/setting_widgets.dart';

class HelpScreen extends StatelessWidget {
  const HelpScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final faqs = <(String, String)>[
      (l10n.helpFaqQ1, l10n.helpFaqA1),
      (l10n.helpFaqQ2, l10n.helpFaqA2),
      (l10n.helpFaqQ3, l10n.helpFaqA3),
      (l10n.helpFaqQ4, l10n.helpFaqA4),
    ];

    return AppScaffold(
      appBar: AppBar(
        title: Text(l10n.helpTitle),
        leading: const BackButton(),
      ),
      body: ListView(
        padding: const EdgeInsets.only(top: AppSpacing.md, bottom: 64),
        children: [
          Text(
            l10n.helpSubtitle,
            style:
                AppTypography.body.copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: AppSpacing.lg),
          Padding(
            padding: const EdgeInsets.only(
              left: AppSpacing.xs,
              bottom: AppSpacing.xs,
            ),
            child: Text(
              l10n.helpFaqSection.toUpperCase(),
              style: AppTypography.overline,
            ),
          ),
          GlassCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (final (i, faq) in faqs.indexed) ...[
                  _FaqTile(question: faq.$1, answer: faq.$2),
                  if (i < faqs.length - 1)
                    const Divider(
                      color: AppColors.hairlineSoft,
                      height: 1,
                      indent: AppSpacing.md,
                      endIndent: AppSpacing.md,
                    ),
                ],
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          SettingSection(
            title: l10n.helpContactSection,
            children: [
              SettingTile(
                icon: Icons.mail_outline_rounded,
                title: l10n.helpContactCta,
                subtitle: l10n.helpContactBody,
                onTap: () {
                  // We don't ship url_launcher in this MVP — surface a clear
                  // confirmation snack so the action isn't a dead tap.
                  context.showSnack('support@datenow.app');
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _FaqTile extends StatefulWidget {
  const _FaqTile({required this.question, required this.answer});

  final String question;
  final String answer;

  @override
  State<_FaqTile> createState() => _FaqTileState();
}

class _FaqTileState extends State<_FaqTile> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => setState(() => _open = !_open),
        child: AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
          alignment: Alignment.topCenter,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.md,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.question,
                        style: AppTypography.bodyStrong,
                      ),
                    ),
                    Icon(
                      _open
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      color: AppColors.textSecondary,
                    ),
                  ],
                ),
                if (_open) ...[
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    widget.answer,
                    style: AppTypography.body.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
