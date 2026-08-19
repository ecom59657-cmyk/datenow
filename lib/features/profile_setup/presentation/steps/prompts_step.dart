import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_spacing.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../../shared/widgets/app_card.dart';
import '../../domain/prompt.dart';
import '../../domain/prompt_answer.dart';
import '../providers/profile_setup_controller.dart';

/// Wizard step where the profile gets its only human sentences.
///
/// Everything else on a DateNow profile is an enum. These answers are the
/// only thing the other person reads before speaking, and — unlike a photo
/// app — they are also what carries the first ten seconds of the call.
///
/// Two are required, not three: the wizard already had four steps, and a
/// third mandatory answer costs more signups than it is worth. The bank is
/// closed on purpose; a free-text bio produces empty paragraphs and a
/// moderation load nobody here can carry.
class PromptsStep extends ConsumerWidget {
  const PromptsStep({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
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
          _PromptSlot(
            slot: slot,
            answer: slot < answered.length ? answered[slot] : null,
            // A question already used elsewhere must not be offered twice.
            taken: answered.map((a) => a.question).toSet(),
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
      ],
    );
  }
}

class _PromptSlot extends ConsumerStatefulWidget {
  const _PromptSlot({
    required this.slot,
    required this.answer,
    required this.taken,
  });

  final int slot;
  final PromptAnswer? answer;
  final Set<PromptQuestion> taken;

  @override
  ConsumerState<_PromptSlot> createState() => _PromptSlotState();
}

class _PromptSlotState extends ConsumerState<_PromptSlot> {
  late final TextEditingController _ctrl =
      TextEditingController(text: widget.answer?.answer ?? '');

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _pickQuestion() async {
    final l10n = AppLocalizations.of(context);
    final available = PromptQuestion.values
        .where((q) => !widget.taken.contains(q) || q == widget.answer?.question)
        .toList(growable: false);

    final picked = await showModalBottomSheet<PromptQuestion>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                0,
                AppSpacing.lg,
                AppSpacing.sm,
              ),
              child: Text(l10n.promptsChooseQuestion, style: AppTypography.h3),
            ),
            for (final q in available)
              ListTile(
                title: Text(q.label(l10n), style: AppTypography.bodyStrong),
                onTap: () => Navigator.of(ctx).pop(q),
              ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    // Swapping the question keeps whatever was typed: the answer usually
    // still fits, and retyping it is the fastest way to lose someone.
    final previous = widget.answer?.question;
    if (previous != null && previous != picked) {
      ref.read(profileSetupControllerProvider.notifier).setPrompt(previous, '');
    }
    ref
        .read(profileSetupControllerProvider.notifier)
        .setPrompt(picked, _ctrl.text);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final question = widget.answer?.question;

    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: _pickQuestion,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    question?.label(l10n) ?? l10n.promptsChooseQuestion,
                    style: AppTypography.bodyStrong.copyWith(
                      color: question == null
                          ? AppColors.bordeaux
                          : AppColors.ink,
                    ),
                  ),
                ),
                const Icon(
                  Icons.expand_more_rounded,
                  color: AppColors.ink3,
                  size: 20,
                ),
              ],
            ),
          ),
          if (question != null) ...[
            const SizedBox(height: AppSpacing.xs),
            TextField(
              controller: _ctrl,
              maxLength: PromptRules.maxAnswerLength,
              maxLines: 2,
              minLines: 1,
              textCapitalization: TextCapitalization.sentences,
              inputFormatters: [
                LengthLimitingTextInputFormatter(PromptRules.maxAnswerLength),
              ],
              style: AppTypography.body.copyWith(color: AppColors.ink),
              decoration: InputDecoration(
                hintText: question.hint(l10n),
                counterStyle: AppTypography.caption,
                border: InputBorder.none,
                contentPadding: EdgeInsets.zero,
              ),
              onChanged: (value) => ref
                  .read(profileSetupControllerProvider.notifier)
                  .setPrompt(question, value),
            ),
          ],
        ],
      ),
    );
  }
}
