import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_spacing.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../core/utils/extensions.dart';
import '../../../../core/utils/logger.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../../shared/widgets/app_button.dart';
import '../../../../shared/widgets/app_error_state.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../../profile_setup/data/profile_repository.dart';
import '../../../profile_setup/domain/prompt.dart';
import '../../../profile_setup/domain/prompt_answer.dart';
import '../../../profile_setup/presentation/providers/profile_provider.dart';
import '../../../profile_setup/presentation/widgets/prompt_slot_editor.dart';
import '../../../settings/presentation/widgets/destructive_dialog.dart';

/// Edit the prompt answers after signup.
///
/// Without this the answers were reachable only from the signup wizard, so
/// every account that already existed could never have any — and anyone who
/// answered badly was stuck with it. Prompts are deliberately not part of
/// [UserProfile.isComplete] (adding them would have pushed the whole user
/// base back through the wizard), which is exactly why they need a door of
/// their own here.
class EditPromptsScreen extends ConsumerStatefulWidget {
  const EditPromptsScreen({super.key});

  @override
  ConsumerState<EditPromptsScreen> createState() => _EditPromptsScreenState();
}

class _EditPromptsScreenState extends ConsumerState<EditPromptsScreen> {
  static const _log = AppLogger('EditPrompts');

  List<PromptAnswer>? _draft;
  List<PromptAnswer> _initial = const [];
  bool _saving = false;

  void _populateFrom(List<PromptAnswer> prompts) {
    if (_draft != null) return;
    _draft = [...prompts];
    _initial = [...prompts];
  }

  bool get _isDirty {
    final draft = _draft ?? const <PromptAnswer>[];
    if (draft.length != _initial.length) return true;
    for (var i = 0; i < draft.length; i++) {
      if (draft[i].question != _initial[i].question ||
          draft[i].answer.trim() != _initial[i].answer.trim()) {
        return true;
      }
    }
    return false;
  }

  void _apply(int slot, PromptQuestion? question, String answer) {
    final next = [...?_draft];
    final previous = slot < next.length ? next[slot] : null;
    if (previous != null) next.removeAt(slot);
    if (question != null && answer.trim().isNotEmpty) {
      final at = slot.clamp(0, next.length);
      next.insert(at, PromptAnswer(question: question, answer: answer.trim()));
    }
    for (var i = 0; i < next.length; i++) {
      next[i] = next[i].copyWith(position: i);
    }
    setState(() => _draft = next);
  }

  Future<void> _confirmDiscard(bool didPop) async {
    if (didPop || !_isDirty || !mounted) return;
    final l10n = AppLocalizations.of(context);
    final discard = await showDestructiveConfirm(
      context: context,
      title: l10n.discardChangesTitle,
      body: l10n.discardChangesBody,
      confirmLabel: l10n.discardChangesAction,
    );
    if (!discard || !mounted) return;
    Navigator.of(context).pop();
  }

  Future<void> _save() async {
    final profile = ref.read(currentProfileProvider).asData?.value;
    if (profile == null || _draft == null) return;
    setState(() => _saving = true);
    try {
      await ref
          .read(profileRepositoryProvider)
          .saveProfile(profile.copyWith(prompts: _draft!));
      if (!mounted) return;
      setState(() => _initial = [..._draft!]);
      if (!mounted) return;
      context.showSnack(AppLocalizations.of(context).savedSnack);
    } catch (e, st) {
      _log.error('saving prompts failed', e, st);
      if (!mounted) return;
      context.showSnack(AppLocalizations.of(context).errorSaveGeneric);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final profileAsync = ref.watch(currentProfileProvider);

    return profileAsync.when(
      loading: () => const AppScaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => AppScaffold(
        body: AppErrorState(
          message: l10n.errorLoadProfile,
          onRetry: () => ref.invalidate(currentProfileProvider),
        ),
      ),
      data: (profile) {
        if (profile == null) {
          return const AppScaffold(body: SizedBox.shrink());
        }
        _populateFrom(profile.filledPrompts);
        final draft = _draft ?? const <PromptAnswer>[];

        return PopScope(
          canPop: !_isDirty,
          onPopInvokedWithResult: (didPop, _) => _confirmDiscard(didPop),
          child: AppScaffold(
            appBar: AppBar(title: Text(l10n.editPromptsTitle)),
            body: Column(
              children: [
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.only(top: AppSpacing.sm),
                    children: [
                      Text(l10n.editPromptsBody, style: AppTypography.body),
                      const SizedBox(height: AppSpacing.lg),
                      for (var slot = 0;
                          slot < PromptRules.maxAnswered;
                          slot++) ...[
                        PromptSlotEditor(
                          // Keyed on the slot ONLY. Including the question
                          // meant the key changed the instant the first
                          // character made an answer exist, so Flutter
                          // threw the State away mid-word: the controller
                          // was rebuilt empty and the field closed after
                          // one letter. Syncing with the parent is
                          // didUpdateWidget's job, not the key's.
                          key: ValueKey('edit-prompt-$slot'),
                          answer: slot < draft.length ? draft[slot] : null,
                          taken: draft.map((a) => a.question).toSet(),
                          onChanged: (question, answer) =>
                              _apply(slot, question, answer),
                        ),
                        const SizedBox(height: AppSpacing.sm),
                      ],
                      const SizedBox(height: AppSpacing.xxl),
                    ],
                  ),
                ),
                // Action bar rather than a button adrift at the bottom of
                // an empty screen: the hairline gives it a home, and the
                // line above says what state the answers are in, which is
                // the question people were asking when they went looking
                // for a confirmation.
                Container(
                  decoration: const BoxDecoration(
                    border: Border(
                      top: BorderSide(color: AppColors.line),
                    ),
                  ),
                  padding: const EdgeInsets.only(top: AppSpacing.sm),
                  child: Column(
                    children: [
                      Text(
                        _isDirty
                            ? l10n.editPromptsUnsaved
                            : l10n.editPromptsSaved,
                        style: AppTypography.caption.copyWith(
                          color: _isDirty ? AppColors.amber : AppColors.sage,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      AppButton(
                        label: l10n.saveAction,
                        size: AppButtonSize.large,
                        isLoading: _saving,
                        onPressed: _isDirty && !_saving ? _save : null,
                      ),
                      const SizedBox(height: AppSpacing.md),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
