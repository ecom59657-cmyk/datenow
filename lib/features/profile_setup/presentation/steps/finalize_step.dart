import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_spacing.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../l10n/app_localizations.dart';
import '../../domain/enums.dart';
import '../providers/profile_setup_controller.dart';
import '../widgets/choice_card.dart';
import '../widgets/photo_picker_card.dart';

class FinalizeStep extends ConsumerWidget {
  const FinalizeStep({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final ctrl = ref.read(profileSetupControllerProvider.notifier);
    final draft = ref.watch(profileSetupControllerProvider);

    return ListView(
      padding: EdgeInsets.zero,
      children: [
        Text(l10n.step4Title, style: AppTypography.h1),
        const SizedBox(height: AppSpacing.xs),
        Text(
          l10n.step4Subtitle,
          style: AppTypography.body.copyWith(color: AppColors.textSecondary),
        ),
        const SizedBox(height: AppSpacing.xl),
        _Label(l10n.availabilityLabel),
        const SizedBox(height: AppSpacing.sm),
        Column(
          children: [
            for (final availability in Availability.values) ...[
              ChoiceCard(
                title: availability.title(l10n),
                body: availability.body(l10n),
                icon: availability == Availability.immediate
                    ? Icons.bolt_rounded
                    : Icons.notifications_active_outlined,
                selected: draft.availability == availability,
                onTap: () => ctrl.setAvailability(availability),
              ),
              const SizedBox(height: AppSpacing.sm),
            ],
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _Label(l10n.photoLabel),
            Text(
              l10n.photoRequired,
              style: AppTypography.caption.copyWith(
                color: AppColors.textTertiary,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        PhotoPickerCard(
          bytes: draft.photoBytes,
          onPicked: ctrl.setPhotoBytes,
        ),
        const SizedBox(height: AppSpacing.xxl),
      ],
    );
  }
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
