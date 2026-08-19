import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_spacing.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../l10n/app_localizations.dart';
import '../../domain/prompt.dart';
import '../providers/profile_setup_controller.dart';
import '../widgets/prompt_slot_editor.dart';

/// Wizard step where the profile gets its only human sentences.
///
/// Everything else on a DateNow profile is an enum. These answers are the
/// only thing the other person reads before speaking, and — unlike a photo
/// app — they are also what carries the first ten seconds of the call.
///
/// Two are required, not three: the wizard already had four steps, and a
/// third mandatory answer costs more signups than it is worth.
class PromptsStep extends ConsumerWidget {
  const PromptsStep({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final ctrl = ref.read(profileSetupControllerProvider.notifier);
    final draft = ref.watch(profileSetupControllerProvider);
    final answered = draft.filledPrompts;
    final remaining =
        (PromptRules.minAnswered - answered.length).clamp(0, 99);

    return ListView(
      padding: EdgeInsets.zero,
      children: [
        Text(l10n.promptsStepTitle, style: AppTypography.h1),
        const SizedBox(height: AppSpacing.xs),
        Text(l10n.promptsStepBody, style: AppTypography.body),
        const SizedBox(height: AppSpacing.sm),
        Text(
          l10n.promptsStepCounter(
            remaining,
            PromptRules.minAnswered,
            answered.length,
          ),
          style: AppTypography.caption.copyWith(
            color: remaining == 0 ? AppColors.sage : AppColors.ink2,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        for (var slot = 0; slot < PromptRules.maxAnswered; slot++) ...[
          PromptSlotEditor(
            key: ValueKey('wizard-prompt-$slot'),
            answer: slot < answered.length ? answered[slot] : null,
            taken: answered.map((a) => a.question).toSet(),
            onChanged: (question, value) {
              final previous =
                  slot < answered.length ? answered[slot].question : null;
              if (previous != null && previous != question) {
                ctrl.setPrompt(previous, '');
              }
              if (question != null) ctrl.setPrompt(question, value);
            },
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
      ],
    );
  }
}
