import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/app_routes.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../core/utils/extensions.dart';
import '../../../core/utils/logger.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/app_button.dart';
import '../../../shared/widgets/app_scaffold.dart';
import '../../onboarding/presentation/providers/onboarding_provider.dart';
import 'providers/profile_setup_controller.dart';
import 'steps/finalize_step.dart';
import 'steps/identity_step.dart';
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
  static const _stepCount = 4;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  bool _validForStep(int i, ProfileDraft d) => switch (i) {
        0 => d.isStep1Valid,
        1 => d.isStep2Valid,
        2 => d.isStep3Valid,
        3 => d.isStep4Valid,
        _ => false,
      };

  bool get _isLast => _index == _stepCount - 1;

  Future<void> _next() async {
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

    return AppScaffold(
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
              children: const [
                IdentityStep(),
                SeekingStep(),
                VibeStep(),
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
                color: active ? AppColors.brandPink : AppColors.hairline,
                borderRadius: BorderRadius.circular(99),
              ),
            );
          }),
        ),
      ],
    );
  }
}
