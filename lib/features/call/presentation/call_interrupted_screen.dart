import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/app_routes.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../core/utils/logger.dart';
import '../../../shared/widgets/app_button.dart';
import '../../../shared/widgets/app_scaffold.dart';
import '../domain/call_end_reason.dart';

/// Shown instead of `PostCallScreen` when the call ended for a reason
/// that did NOT include both users completing the date (see
/// `CallEndReason.isInterrupted`).
///
/// Deliberately neutral — no photo reveal, no compatibility score, no
/// romantic flourish. The DateNow product promise is that the photo
/// reveal only happens after a real shared 5-minute exchange, so any
/// interrupted flow lands here instead.
///
/// CTAs :
///   * Primary  : return home so the user can immediately try again.
///   * Optional : direct "Relancer un date" shortcut — for now wired
///                to the same home destination (the find-a-date CTA
///                lives there). When we ship a deep-link straight to
///                the matching screen, this button gets that target.
class CallInterruptedScreen extends ConsumerStatefulWidget {
  const CallInterruptedScreen({super.key});

  @override
  ConsumerState<CallInterruptedScreen> createState() =>
      _CallInterruptedScreenState();
}

class _CallInterruptedScreenState
    extends ConsumerState<CallInterruptedScreen> {
  static const _log = AppLogger('Call');

  @override
  void initState() {
    super.initState();
    final reason = ref.read(lastCallEndReasonProvider);
    _log.info(
      'CallInterruptedScreen mounted — reason=${reason?.name ?? "unknown"}',
    );
  }

  @override
  void dispose() {
    // Clear so the next call starts fresh — without this the next
    // postCall could in theory pick up a stale reason from a previous
    // session.
    Future.microtask(() {
      if (!mounted) {
        ref.read(lastCallEndReasonProvider.notifier).state = null;
      }
    });
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reason = ref.watch(lastCallEndReasonProvider);
    final (title, body) = _copyFor(reason);

    return AppScaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(flex: 2),
              const _DisconnectIcon(),
              const SizedBox(height: AppSpacing.xl),
              Text(
                title,
                textAlign: TextAlign.center,
                style: AppTypography.h1,
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                body,
                textAlign: TextAlign.center,
                style: AppTypography.body.copyWith(
                  color: AppColors.textSecondary,
                ),
              ),
              const Spacer(flex: 3),
              AppButton(
                label: 'Retour à l\'accueil',
                size: AppButtonSize.large,
                onPressed: () => _goHome(context),
              ),
              const SizedBox(height: AppSpacing.sm),
              AppButton(
                label: 'Relancer un date',
                variant: AppButtonVariant.secondary,
                onPressed: () => _goHome(context),
              ),
              const SizedBox(height: AppSpacing.lg),
            ],
          ),
        ),
      ),
    );
  }

  /// Per-reason wording. Title stays consistent ("Le date s'est
  /// interrompu") so the user always understands the outcome at a
  /// glance; only the body line shifts to be honest about the root
  /// cause when we know it.
  (String title, String body) _copyFor(CallEndReason? reason) {
    const title = 'Le date s\'est interrompu';
    final body = switch (reason) {
      CallEndReason.remoteTimeout =>
        'Votre date a quitté la conversation avant la fin de l\'échange.',
      CallEndReason.networkLost =>
        'Votre connexion internet s\'est coupée pendant le date. '
            'Réessaie quand le réseau est stable.',
      CallEndReason.appBackgroundTimeout =>
        'L\'application est restée trop longtemps en arrière-plan, '
            'le date a été clôturé.',
      CallEndReason.appDetached =>
        'L\'application a été fermée pendant le date.',
      CallEndReason.unknown || null =>
        'La connexion avec votre date a été perdue avant la fin de '
            'l\'échange.',
      _ =>
        'La connexion avec votre date a été perdue avant la fin de '
            'l\'échange.',
    };
    return (title, body);
  }

  void _goHome(BuildContext context) {
    _log.info('CallInterruptedScreen — user tapped CTA, going home');
    if (context.canPop()) {
      context.goNamed(AppRoute.home.name);
    } else {
      context.goNamed(AppRoute.home.name);
    }
  }
}

class _DisconnectIcon extends StatelessWidget {
  const _DisconnectIcon();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 96,
      height: 96,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppColors.textTertiary.withValues(alpha: 0.12),
        border: Border.all(
          color: AppColors.textTertiary.withValues(alpha: 0.25),
          width: 1.5,
        ),
      ),
      child: const Icon(
        Icons.signal_wifi_connected_no_internet_4_rounded,
        size: 40,
        color: AppColors.textTertiary,
      ),
    );
  }
}
