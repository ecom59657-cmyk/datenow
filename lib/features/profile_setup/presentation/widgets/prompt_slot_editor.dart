import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_spacing.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../../shared/widgets/app_card.dart';
import '../../domain/prompt.dart';
import '../../domain/prompt_answer.dart';

/// One prompt slot: pick a question, type an answer.
///
/// Shared by the signup wizard and the profile editor so the two cannot
/// drift — the character limit, the "a question can only be used once"
/// rule and the swap-keeps-your-text behaviour live here, not in each
/// screen.
class PromptSlotEditor extends StatefulWidget {
  const PromptSlotEditor({
    super.key,
    required this.answer,
    required this.taken,
    required this.onChanged,
  });

  /// Current content of this slot, `null` when empty.
  final PromptAnswer? answer;

  /// Questions used by the other slots — offering one twice would produce
  /// a row the UNIQUE(user_id, question) constraint rejects.
  final Set<PromptQuestion> taken;

  /// `question == null` means the slot was emptied.
  final void Function(PromptQuestion? question, String answer) onChanged;

  @override
  State<PromptSlotEditor> createState() => _PromptSlotEditorState();
}

class _PromptSlotEditorState extends State<PromptSlotEditor> {
  late final TextEditingController _ctrl =
      TextEditingController(text: widget.answer?.answer ?? '');

  /// The question being answered, held HERE and not derived from
  /// [widget.answer].
  ///
  /// The parent only stores answers that have text — an empty one is not an
  /// answer. So between picking a question and typing the first character
  /// there is a state the parent cannot represent, and deriving the field's
  /// visibility from the parent made that state invisible: you could choose
  /// a question and then nothing happened, because the text field was
  /// waiting for text that could never be entered.
  late PromptQuestion? _question = widget.answer?.question;

  @override
  void didUpdateWidget(PromptSlotEditor old) {
    super.didUpdateWidget(old);
    // Follow the parent when it genuinely changes the slot (a save, a
    // reload), but never let a null answer wipe a question the user just
    // picked and has not typed into yet.
    final incoming = widget.answer?.question;
    if (incoming != null && incoming != _question) {
      _question = incoming;
      _ctrl.text = widget.answer?.answer ?? '';
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _pickQuestion() async {
    final l10n = AppLocalizations.of(context);
    final current = widget.answer?.question;
    final available = PromptQuestion.values
        .where((q) => !widget.taken.contains(q) || q == current)
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
                trailing: q == current
                    ? const Icon(Icons.check_rounded,
                        color: AppColors.bordeaux, size: 20)
                    : null,
                onTap: () => Navigator.of(ctx).pop(q),
              ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    // Swapping the question keeps what was typed: the answer usually still
    // fits, and making someone retype it is the fastest way to lose them.
    setState(() => _question = picked);
    widget.onChanged(picked, _ctrl.text);
  }

  void _clear() {
    _ctrl.clear();
    setState(() => _question = null);
    widget.onChanged(null, '');
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final question = _question;

    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: InkWell(
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
              ),
              if (question != null)
                IconButton(
                  tooltip: l10n.promptsRemove,
                  onPressed: _clear,
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  icon: const Icon(
                    Icons.close_rounded,
                    size: 18,
                    color: AppColors.ink3,
                  ),
                ),
            ],
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
              onChanged: (value) => widget.onChanged(question, value),
            ),
          ],
        ],
      ),
    );
  }
}
