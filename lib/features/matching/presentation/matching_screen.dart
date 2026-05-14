import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/app_routes.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../core/utils/logger.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/app_button.dart';
import '../../../shared/widgets/app_scaffold.dart';
import '../../profile_setup/presentation/providers/profile_provider.dart';
import '../../profile_setup/presentation/widgets/blurred_avatar.dart';
import '../../quota/data/quota_repository.dart';
import '../data/matching_repository.dart';
import '../domain/active_match.dart';
import 'providers/active_match_provider.dart';
import 'widgets/compatibility_badge.dart';

/// Auto-match screen. Searches for a compatible candidate using
/// [MatchingRepository], shows a short reveal of the score (no photo!), then
/// pushes the user into the live call.
class MatchingScreen extends ConsumerStatefulWidget {
  const MatchingScreen({super.key});

  @override
  ConsumerState<MatchingScreen> createState() => _MatchingScreenState();
}

enum _Phase { searching, found, empty }

class _MatchingScreenState extends ConsumerState<MatchingScreen> {
  Timer? _messageRotator;
  Timer? _navTimer;
  int _step = 0;
  static const _stepCount = 3;

  _Phase _phase = _Phase.searching;
  ActiveMatch? _match;

  @override
  void initState() {
    super.initState();
    _startSearch();
  }

  void _startSearch() {
    setState(() {
      _phase = _Phase.searching;
      _step = 0;
      _match = null;
    });
    _messageRotator?.cancel();
    _messageRotator = Timer.periodic(
      const Duration(seconds: 1, milliseconds: 200),
      (timer) {
        if (_step >= _stepCount - 1) {
          timer.cancel();
          unawaited(_resolveCandidate());
          return;
        }
        setState(() => _step++);
      },
    );
  }

  static const _log = AppLogger('Matching');

  Future<void> _resolveCandidate() async {
    _log.info('Resolving candidate…');
    final self = ref.read(currentProfileProvider).asData?.value;
    if (self == null) {
      _log.warn('Aborting — no current profile.');
      if (mounted) context.pop();
      return;
    }

    ActiveMatch? match;
    try {
      match = await ref.read(matchingRepositoryProvider).findCandidate(self);
    } catch (e, st) {
      _log.error('findCandidate threw: $e', e, st);
      if (!mounted) return;
      setState(() => _phase = _Phase.empty);
      return;
    }
    if (!mounted) return;
    if (match == null) {
      _log.info('No candidate online — showing empty state.');
      setState(() => _phase = _Phase.empty);
      return;
    }

    _log.info(
      'Match found uid=${match.candidate.userId} '
      'score=${match.score.percentage}%',
    );

    // Quota recording is best-effort: never block the call on it.
    try {
      await ref.read(quotaRepositoryProvider).recordMatch(self);
    } catch (e, st) {
      _log.error('recordMatch failed (continuing): $e', e, st);
    }
    if (!mounted) return;

    setState(() {
      _match = match;
      _phase = _Phase.found;
    });
    ref.read(activeMatchProvider.notifier).state = match;
    _navTimer = Timer(const Duration(milliseconds: 1600), () {
      _log.info('Navigating to call');
      _goToCall();
    });
  }

  void _goToCall() {
    if (!mounted) return;
    context.pushReplacementNamed(AppRoute.call.name);
  }

  void _cancel() {
    _messageRotator?.cancel();
    _navTimer?.cancel();
    ref.read(activeMatchProvider.notifier).state = null;
    context.pop();
  }

  @override
  void dispose() {
    _messageRotator?.cancel();
    _navTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return AppScaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: _cancel,
        ),
      ),
      body: switch (_phase) {
        _Phase.searching => _SearchingView(l10n: l10n, step: _step),
        _Phase.found => _FoundView(l10n: l10n, match: _match!),
        _Phase.empty => _EmptyView(l10n: l10n, onRetry: _startSearch),
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Searching
// ---------------------------------------------------------------------------

class _SearchingView extends StatelessWidget {
  const _SearchingView({required this.l10n, required this.step});

  final AppLocalizations l10n;
  final int step;

  @override
  Widget build(BuildContext context) {
    final messages = [
      l10n.matchingStep1,
      l10n.matchingStep2,
      l10n.matchingStep3,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Spacer(flex: 2),
        const Center(child: _RippleAvatar()),
        const SizedBox(height: AppSpacing.xl),
        Text(
          l10n.matchingTitle,
          textAlign: TextAlign.center,
          style: AppTypography.h2,
        ),
        const SizedBox(height: AppSpacing.sm),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          child: Text(
            messages[step],
            key: ValueKey(step),
            textAlign: TextAlign.center,
            style: AppTypography.body.copyWith(
              color: AppColors.textSecondary,
            ),
          ),
        ),
        const Spacer(flex: 3),
        AppButton(
          label: l10n.cancel,
          variant: AppButtonVariant.secondary,
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        const SizedBox(height: AppSpacing.lg),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Found — pre-connect reveal of the score (no photo)
// ---------------------------------------------------------------------------

class _FoundView extends StatelessWidget {
  const _FoundView({required this.l10n, required this.match});

  final AppLocalizations l10n;
  final ActiveMatch match;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Spacer(flex: 2),
        const Center(child: BlurredAvatar(size: 180))
            .animate()
            .scale(
              duration: 360.ms,
              begin: const Offset(0.9, 0.9),
              end: const Offset(1, 1),
              curve: Curves.easeOutBack,
            ),
        const SizedBox(height: AppSpacing.lg),
        Text(
          l10n.matchingFoundTitle,
          textAlign: TextAlign.center,
          style: AppTypography.h1,
        ),
        const SizedBox(height: 4),
        Text(
          '${match.candidate.firstName ?? '—'} · ${match.distanceKm} km',
          textAlign: TextAlign.center,
          style: AppTypography.body.copyWith(color: AppColors.textSecondary),
        ),
        const SizedBox(height: AppSpacing.md),
        Center(child: CompatibilityBadge(score: match.score))
            .animate()
            .fadeIn(delay: 200.ms),
        const SizedBox(height: AppSpacing.sm),
        Text(
          l10n.matchingFoundSubtitle,
          textAlign: TextAlign.center,
          style: AppTypography.caption.copyWith(
            color: AppColors.textTertiary,
          ),
        ),
        const Spacer(flex: 3),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Empty — no compatible candidate online
// ---------------------------------------------------------------------------

class _EmptyView extends StatelessWidget {
  const _EmptyView({required this.l10n, required this.onRetry});

  final AppLocalizations l10n;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Spacer(flex: 2),
        const Icon(
          Icons.hourglass_empty_rounded,
          size: 64,
          color: AppColors.textTertiary,
        ),
        const SizedBox(height: AppSpacing.lg),
        Text(
          l10n.matchingNoCandidateTitle,
          textAlign: TextAlign.center,
          style: AppTypography.h2,
        ),
        const SizedBox(height: AppSpacing.sm),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
          child: Text(
            l10n.matchingNoCandidateBody,
            textAlign: TextAlign.center,
            style: AppTypography.body.copyWith(
              color: AppColors.textSecondary,
            ),
          ),
        ),
        const Spacer(flex: 3),
        AppButton(
          label: l10n.matchingTryAgain,
          size: AppButtonSize.large,
          onPressed: onRetry,
        ),
        const SizedBox(height: AppSpacing.sm),
        AppButton(
          label: l10n.cancel,
          variant: AppButtonVariant.secondary,
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        const SizedBox(height: AppSpacing.lg),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Ripple avatar (kept private to this file — only used while searching)
// ---------------------------------------------------------------------------

class _RippleAvatar extends StatelessWidget {
  const _RippleAvatar();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 240,
      height: 240,
      child: Stack(
        alignment: Alignment.center,
        children: [
          for (var i = 0; i < 3; i++) _Ripple(delayMs: i * 600),
          Container(
            width: 112,
            height: 112,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: AppColors.brandGradient,
              boxShadow: [
                BoxShadow(
                  color: AppColors.brandPink.withValues(alpha: 0.5),
                  blurRadius: 40,
                  spreadRadius: 6,
                ),
              ],
            ),
            child: const Icon(Icons.favorite_rounded,
                color: Colors.white, size: 48),
          ),
        ],
      ),
    );
  }
}

class _Ripple extends StatelessWidget {
  const _Ripple({required this.delayMs});

  final int delayMs;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 120,
      height: 120,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: AppColors.brandPink, width: 1.5),
      ),
    )
        .animate(onPlay: (c) => c.repeat())
        .scaleXY(
          duration: 2200.ms,
          delay: Duration(milliseconds: delayMs),
          begin: 1.0,
          end: 2.0,
          curve: Curves.easeOut,
        )
        .fadeOut(
          duration: 2200.ms,
          delay: Duration(milliseconds: delayMs),
        );
  }
}
