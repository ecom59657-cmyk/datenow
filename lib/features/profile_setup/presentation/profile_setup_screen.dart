import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/app_routes.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../core/utils/age.dart';
import '../../../core/utils/extensions.dart';
import '../../../core/utils/logger.dart';
import '../../../core/services/location_service.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/app_button.dart';
import '../../../shared/widgets/app_scaffold.dart';
import '../../onboarding/presentation/providers/onboarding_provider.dart';
import 'providers/profile_setup_controller.dart';
import 'steps/background_step.dart';
import 'steps/finalize_step.dart';
import 'steps/identity_step.dart';
import '../domain/prompt_moderation.dart';
import 'widgets/prompt_rejected_sheet.dart';
import 'steps/prompts_step.dart';
import 'steps/seeking_step.dart';
import 'steps/vibe_step.dart';

/// Multi-step onboarding the user goes through right after sign-up. The
/// router blocks `/home` until [ProfileDraft.isComplete] flips to `true`,
/// so this is the only path from auth to the main app.
class ProfileSetupScreen extends ConsumerStatefulWidget {
  const ProfileSetupScreen({super.key});

  @override
  ConsumerState<ProfileSetupScreen> createState() => _ProfileSetupScreenState();
}

class _ProfileSetupScreenState extends ConsumerState<ProfileSetupScreen> {
  final _pageController = PageController();
  int _index = 0;
  bool _submitting = false;

  /// The wizard in order. Named rather than numbered because the mapping
  /// used to be positional — `0 => isStep1Valid … 3 => isStep5Valid,
  /// 4 => isStep4Valid` — with the prompts moderation gate keyed on the
  /// literal `_index == 3`. Inserting a step meant renumbering three
  /// separate places by hand, and getting it wrong showed up as a wizard
  /// that silently validates the wrong answers.
  static const _steps = <_Step>[
    _Step.identity,
    _Step.background,
    _Step.seeking,
    _Step.vibe,
    _Step.prompts,
    _Step.finalize,
  ];

  static int get _stepCount => _steps.length;

  _Step get _current => _steps[_index];

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  bool _validForStep(int i, ProfileDraft d) => switch (_steps[i]) {
        _Step.identity => d.isStep1Valid,
        // Every field on this step is optional, so it is never a blocker.
        // Someone sharing none of it loses a tap, not a signup.
        _Step.background => true,
        _Step.seeking => d.isStep2Valid,
        _Step.vibe => d.isStep3Valid,
        _Step.prompts => d.isStep5Valid,
        // A photo is required to finish signup — the reveal is the
        // product payoff, and the find-date gate demands one anyway.
        // Asking here beats bouncing someone off the CTA later.
        _Step.finalize => d.isFinalizeStepValid,
      };

  bool get _isLast => _index == _stepCount - 1;

  Future<void> _next() async {
    // Prompts are checked before leaving their step, not at submit.
    // saveProfile deliberately swallows a prompts write failure — losing a
    // whole signup over one answer would be worse — so a refused answer
    // would otherwise vanish in silence and the user would finish signup
    // without the sentences they just wrote.
    if (_current == _Step.prompts) {
      final draft = ref.read(profileSetupControllerProvider);
      for (final answer in draft.filledPrompts) {
        final reason = PromptModeration.check(answer.answer);
        if (reason != null) {
          if (!mounted) return;
          await showPromptRejectedSheet(context, reason);
          return;
        }
      }
    }

    if (_isLast) {
      await _submit();
      return;
    }
    _pageController.nextPage(
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  void _back() {
    if (_index == 0) return;
    _pageController.previousPage(
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  static const _log = AppLogger('ProfileSetupScreen');

  Future<void> _submit() async {
    if (_submitting) {
      _log.warn('Submit ignored — already submitting.');
      return;
    }
    _log.info('Submit button clicked');

    setState(() => _submitting = true);
    final l10n = AppLocalizations.of(context);

    try {
      final ok =
          await ref.read(profileSetupControllerProvider.notifier).submit();
      if (!mounted) return;
      if (!ok) {
        _log.warn('Submit returned false — draft incomplete');
        context.showSnack(l10n.profileSetupIncomplete);
        return;
      }
      _log.info('Profile saved — finalising onboarding flag');

      // Push the position now that the profiles row certainly exists.
      // Permission was granted on the last step, so this opens no dialog —
      // it just spares the first "Lancer un date" a GPS read it would
      // otherwise do while the user waits on a spinner.
      unawaited(LocationService.instance.captureAndPush());
      // Belt-and-suspenders: make sure the intro-onboarding flag is on
      // (it should already be from the welcome carousel) so the router
      // never bounces back to /onboarding while the redirect re-evaluates.
      await ref.read(onboardingControllerProvider).complete();

      if (!mounted) return;
      _log.info('Redirecting to /permissions');
      // Route through the permissions screen FIRST so iOS gets a chance
      // to show the native camera/mic prompts before the user ever taps
      // "match" — without this they reach the call screen with denied
      // permissions and no path to recover. The permissions screen
      // forwards to /home once both grants are in (or the user skips).
      context.goNamed(AppRoute.permissions.name);
    } catch (e, st) {
      _log.error('Submit threw: $e', e, st);
      if (!mounted) return;
      context.showSnack(l10n.profileSetupSaveError(_humanError(e)));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  String _humanError(Object e) {
    final raw = e.toString();
    // Strip the leading "Exception: " or "PostgrestException(...)" noise so
    // the snackbar stays readable.
    return raw.length > 140 ? '${raw.substring(0, 140)}…' : raw;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final draft = ref.watch(profileSetupControllerProvider);
    final canContinue = _validForStep(_index, draft) && !_submitting;

    // TEMP — diagnostic for the step-1 "Continuer" bug. Logs every
    // rebuild with the values driving `canContinue` so the actual
    // blocker is visible in Mac Console.app (filter: ProfileSetupScreen).
    // Remove this `_log.info` once the onboarding flow is stable.
    _log.info(
      'build step=$_index canContinue=$canContinue submitting=$_submitting '
      'firstName="${draft.firstName ?? "<null>"}" '
      'birthDate=${draft.birthDate?.toIso8601String() ?? "<null>"} '
      'isOfMinAge=${draft.birthDate == null ? "n/a" : isOfMinimumAge(draft.birthDate!)} '
      'gender=${draft.gender?.name ?? "<null>"} '
      'orientation=${draft.orientation?.name ?? "<null>"} '
      'isStep1Valid=${draft.isStep1Valid} '
      'isStep2Valid=${draft.isStep2Valid} '
      'isStep3Valid=${draft.isStep3Valid} '
      'isStep4Valid=${draft.isStep4Valid}',
    );

    // System back walks the wizard backwards. Without this, an Android
    // back press on step 3 dropped the user out of onboarding entirely
    // and lost every answer.
    return PopScope(
      canPop: _index == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || _index == 0) return;
        _back();
      },
      child: AppScaffold(
      appBar: AppBar(
        leading: _index == 0
            ? null
            : IconButton(
                icon: const Icon(Icons.arrow_back_rounded),
                onPressed: _back,
              ),
        title: _StepProgress(current: _index + 1, total: _stepCount),
        centerTitle: true,
        automaticallyImplyLeading: false,
      ),
      body: Column(
        children: [
          Expanded(
            child: PageView(
              controller: _pageController,
              physics: const NeverScrollableScrollPhysics(),
              onPageChanged: (i) => setState(() => _index = i),
              // Same order as `_steps`, and the two are pinned together by
              // profile_setup_steps_test.dart.
              children: const [
                IdentityStep(),
                BackgroundStep(),
                SeekingStep(),
                VibeStep(),
                PromptsStep(),
                FinalizeStep(),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          AppButton(
            label: _isLast
                ? l10n.profileSetupSubmit
                : l10n.profileSetupContinue,
            size: AppButtonSize.large,
            isLoading: _submitting,
            onPressed: canContinue ? _next : null,
          ),
          const SizedBox(height: AppSpacing.lg),
        ],
      ),
      ),
    );
  }
}

class _StepProgress extends StatelessWidget {
  const _StepProgress({required this.current, required this.total});

  final int current;
  final int total;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          l10n.profileSetupStepProgress(current, total),
          style: AppTypography.caption.copyWith(
            color: AppColors.textSecondary,
            letterSpacing: 0.3,
          ),
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(total, (i) {
            final active = i < current;
            return AnimatedContainer(
              duration: const Duration(milliseconds: 240),
              margin: const EdgeInsets.symmetric(horizontal: 3),
              height: 4,
              width: active ? 28 : 14,
              decoration: BoxDecoration(
                color: active ? AppColors.bordeaux : AppColors.hairline,
                borderRadius: BorderRadius.circular(99),
              ),
            );
          }),
        ),
      ],
    );
  }
}

/// The wizard's steps, in order. Private: nothing outside this screen has
/// any business knowing how signup is paginated.
enum _Step { identity, background, seeking, vibe, prompts, finalize }
