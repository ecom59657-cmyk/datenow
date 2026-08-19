import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_spacing.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../l10n/app_localizations.dart';
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

  /// Whether this slot is being typed into.
  ///
  /// A filled slot at rest renders as the finished card, not as a text
  /// field. That difference is the whole point: a caret still blinking in
  /// an answer you already wrote reads as "not saved yet", so people keep
  /// looking for a confirmation that was never missing. Hinge does the
  /// same — you write, you close, it becomes an object.
  bool _editing = false;

  final FocusNode _focus = FocusNode();

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
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus && _editing && mounted) {
        setState(() => _editing = false);
      }
    });
  }

  @override
  void dispose() {
    _focus.dispose();
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
      // Capped so it stays a sheet. Sixteen questions in an unbounded
      // scroll view filled the screen edge to edge, which stops reading as
      // a choice you can back out of and starts reading as a page you got
      // sent to.
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.72,
      ),
      builder: (ctx) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.xs,
                AppSpacing.lg,
                AppSpacing.md,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l10n.promptsChooseQuestion, style: AppTypography.h2),
                  const SizedBox(height: 2),
                  Text(l10n.promptsPickerHint, style: AppTypography.caption),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
                itemCount: available.length,
                separatorBuilder: (_, _) => const Divider(
                  height: 1,
                  indent: AppSpacing.lg,
                  endIndent: AppSpacing.lg,
                  color: AppColors.lineSoft,
                ),
                itemBuilder: (_, i) {
                  final q = available[i];
                  final isCurrent = q == current;
                  return ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.lg,
                      vertical: 2,
                    ),
                    // Serif, because that is how the question is set on the
                    // card the answer ends up in.
                    title: Text(
                      q.label(l10n),
                      style: AppTypography.h3.copyWith(
                        fontSize: 17,
                        color: isCurrent ? AppColors.bordeaux : AppColors.ink,
                      ),
                    ),
                    trailing: isCurrent
                        ? const Icon(
                            Icons.check_rounded,
                            color: AppColors.bordeaux,
                            size: 20,
                          )
                        : null,
                    onTap: () => Navigator.of(ctx).pop(q),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    // Swapping the question keeps what was typed: the answer usually still
    // fits, and making someone retype it is the fastest way to lose them.
    setState(() {
      _question = picked;
      _editing = true;
    });
    widget.onChanged(picked, _ctrl.text);
  }

  void _clear() {
    _ctrl.clear();
    setState(() {
      _question = null;
      _editing = false;
    });
    widget.onChanged(null, '');
  }

  void _done() {
    _focus.unfocus();
    setState(() => _editing = false);
  }

  void _edit() {
    setState(() => _editing = true);
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final question = _question;

    // Empty slot: an invitation, not a blank card. It used to be a white
    // rectangle with a line of text, which read as a disabled field rather
    // than as something to tap.
    if (question == null) {
      return InkWell(
        onTap: _pickQuestion,
        borderRadius: AppRadius.brLg,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.lg,
          ),
          decoration: BoxDecoration(
            color: AppColors.tint.withValues(alpha: 0.45),
            borderRadius: AppRadius.brLg,
            border: Border.all(color: AppColors.sandDeep),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.add_rounded,
                size: 18,
                color: AppColors.bordeaux,
              ),
              const SizedBox(width: AppSpacing.xs),
              Text(
                l10n.promptsChooseQuestion,
                style: AppTypography.bodyStrong.copyWith(
                  color: AppColors.bordeaux,
                ),
              ),
            ],
          ),
        ),
      );
    }

    final text = _ctrl.text.trim();

    // At rest with an answer: the finished card. Same shape as the one the
    // other person will read — sand ground, clay overline, serif answer —
    // so what you are editing already looks like the result.
    if (!_editing && text.isNotEmpty) {
      return InkWell(
        onTap: _edit,
        borderRadius: AppRadius.brLg,
        child: Container(
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
                      question.label(l10n).toUpperCase(),
                      style: AppTypography.overline.copyWith(
                        color: AppColors.clay,
                        fontSize: 10,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const Icon(
                    Icons.edit_outlined,
                    size: 15,
                    color: AppColors.ink3,
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(text, style: AppTypography.h3.copyWith(fontSize: 17)),
            ],
          ),
        ),
      );
    }

    // Being written: the field, on paper so the change of mode is obvious,
    // with one way out that confirms rather than a caret left blinking.
    final length = _ctrl.text.characters.length;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.paper,
        borderRadius: AppRadius.brLg,
        border: Border.all(color: AppColors.bordeaux),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            question.label(l10n).toUpperCase(),
            style: AppTypography.overline.copyWith(
              color: AppColors.clay,
              fontSize: 10,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          TextField(
            controller: _ctrl,
            focusNode: _focus,
            maxLength: PromptRules.maxAnswerLength,
            maxLines: 3,
            minLines: 1,
            autofocus: true,
            textInputAction: TextInputAction.done,
            textCapitalization: TextCapitalization.sentences,
            inputFormatters: [
              LengthLimitingTextInputFormatter(PromptRules.maxAnswerLength),
            ],
            cursorColor: AppColors.bordeaux,
            style: AppTypography.h3.copyWith(fontSize: 17),
            decoration: InputDecoration(
              hintText: question.hint(l10n),
              hintStyle: AppTypography.h3.copyWith(
                fontSize: 17,
                color: AppColors.ink3,
              ),
              isDense: true,
              filled: false,
              // Every border spelled out: the global InputDecorationTheme
              // draws a bordeaux capsule on focus, which belongs on a form
              // field and looks like a mistake inside a card.
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              contentPadding: EdgeInsets.zero,
              counterText: '',
            ),
            onChanged: (value) {
              widget.onChanged(question, value);
              setState(() {});
            },
            onSubmitted: (_) => _done(),
          ),
          const SizedBox(height: AppSpacing.xs),
          Row(
            children: [
              _SlotAction(
                icon: Icons.swap_horiz_rounded,
                label: l10n.promptsChangeQuestion,
                onTap: _pickQuestion,
              ),
              const SizedBox(width: AppSpacing.md),
              _SlotAction(
                icon: Icons.close_rounded,
                label: l10n.promptsRemove,
                onTap: _clear,
              ),
              const Spacer(),
              // The count only shows once it starts to matter — a live
              // 0/140 on an empty field reads as pressure.
              if (length > PromptRules.maxAnswerLength - 40) ...[
                Text(
                  '$length/${PromptRules.maxAnswerLength}',
                  style: AppTypography.caption.copyWith(
                    color: length >= PromptRules.maxAnswerLength
                        ? AppColors.amber
                        : AppColors.ink3,
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
              ],
              if (text.isNotEmpty)
                _SlotAction(
                  icon: Icons.check_rounded,
                  label: l10n.promptsDone,
                  onTap: _done,
                  emphasised: true,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Quiet text action inside a slot. Not an AppButton: three filled shapes
/// per card would compete with the one action of the screen.
class _SlotAction extends StatelessWidget {
  const _SlotAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.emphasised = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  /// The one that closes the field — bordeaux so it reads as the way out.
  final bool emphasised;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: AppRadius.brSm,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 15,
              color: emphasised ? AppColors.bordeaux : AppColors.ink2,
            ),
            const SizedBox(width: 5),
            Text(
              label,
              style: AppTypography.caption.copyWith(
                color: emphasised ? AppColors.bordeaux : AppColors.ink2,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
