import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_spacing.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../l10n/app_localizations.dart';
import '../../domain/enums.dart';
import '../../domain/interest.dart';
import '../providers/profile_setup_controller.dart';
import '../widgets/choice_card.dart';
import '../widgets/choice_chip_grid.dart';

class VibeStep extends ConsumerWidget {
  const VibeStep({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final ctrl = ref.read(profileSetupControllerProvider.notifier);
    final draft = ref.watch(profileSetupControllerProvider);

    return ListView(
      padding: EdgeInsets.zero,
      children: [
        Text(l10n.step3Title, style: AppTypography.h1),
        const SizedBox(height: AppSpacing.xs),
        Text(
          l10n.step3Subtitle,
          style: AppTypography.body.copyWith(color: AppColors.textSecondary),
        ),
        const SizedBox(height: AppSpacing.xl),
        _Label(l10n.intentionsLabel),
        const SizedBox(height: AppSpacing.sm),
        Column(
          children: [
            for (final intention in Intention.values) ...[
              ChoiceCard(
                title: intention.label(l10n),
                body: intention.body(l10n),
                icon: _iconFor(intention),
                selected: draft.intentions.contains(intention),
                onTap: () => ctrl.toggleIntention(intention),
              ),
              const SizedBox(height: AppSpacing.sm),
            ],
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _Label(l10n.interestsLabel),
            Text(
              l10n.interestsHint,
              style: AppTypography.caption.copyWith(
                color: AppColors.textTertiary,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        ChoiceChipGrid<Interest>(
          options: Interest.values,
          labelOf: (i) => i.label(l10n),
          isSelected: draft.interests.contains,
          onToggle: ctrl.toggleInterest,
        ),
        const SizedBox(height: AppSpacing.xxl),
      ],
    );
  }

  IconData _iconFor(Intention i) => switch (i) {
        Intention.serious => Icons.favorite_rounded,
        Intention.feeling => Icons.flutter_dash_rounded,
        Intention.talk => Icons.chat_bubble_outline_rounded,
        Intention.casual => Icons.celebration_outlined,
      };
}

class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: AppTypography.caption.copyWith(
        color: AppColors.textSecondary,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.3,
      ),
    );
  }
}
