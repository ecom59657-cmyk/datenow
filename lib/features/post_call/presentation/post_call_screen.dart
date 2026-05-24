import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/app_routes.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../core/debug/debug_observer.dart';
import '../../../core/utils/logger.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/app_button.dart';
import '../../../shared/widgets/app_scaffold.dart';
import '../../discover/data/discover_repository.dart';
import '../../matching/data/matching_repository.dart';
import '../../messaging/data/messaging_repository.dart';
import '../../matching/domain/active_match.dart';
import '../../matching/presentation/providers/active_match_provider.dart';
import '../../matching/presentation/widgets/compatibility_badge.dart';
import '../../profile_setup/data/profile_repository.dart';
import '../../profile_setup/presentation/providers/profile_provider.dart';
import '../../profile_setup/presentation/widgets/blurred_avatar.dart';
import '../../safety/presentation/report_sheet.dart';
import '../data/reveal_repository.dart';

/// Post-call decision screen. Reveals the candidate photo + compatibility
/// score and lets the user match or pass. Real photos surface **only** here.
class PostCallScreen extends ConsumerStatefulWidget {
  const PostCallScreen({super.key});

  @override
  ConsumerState<PostCallScreen> createState() => _PostCallScreenState();
}

enum _Stage { decide, waiting, matched, noMatch, passed }

class _PostCallScreenState extends ConsumerState<PostCallScreen> {
  static const _log = AppLogger('PostCall');

  /// How long to wait on the peer's reveal decision before offering the
  /// user a way out — prevents an infinite "waiting" spinner when the
  /// peer closed the app or never decides.
  static const _revealTimeout = Duration(minutes: 2);

  _Stage _stage = _Stage.decide;
  bool _revealed = false;
  Uint8List? _peerPhotoBytes;
  Timer? _peerDecisionTimer;
  Timer? _revealTimeoutTimer;
  bool _revealTimedOut = false;
  StreamSubscription<List<RevealRow>>? _revealSub;
  bool _matchPersisted = false;

  @override
  void initState() {
    super.initState();
    DebugObserver.instance.setPhase('reveal'); // debug-observer
    _loadPeerPhoto();
  }

  Future<void> _loadPeerPhoto() async {
    // Load the *peer's* primary photo — never the current user's. Showing
    // the wrong photo at reveal would convince testers the match is buggy.
    // If the peer photo can't be resolved (no URL, or RLS denies storage
    // before the match row exists), _PhotoReveal falls back to the
    // blurred placeholder rather than surface a stranger's face.
    final match = ref.read(activeMatchProvider);
    if (match == null) return;
    final peerId = match.candidate.userId;
    final profileRepo = ref.read(profileRepositoryProvider);

    // Refetch in case the cached candidate doesn't yet carry photo URLs
    // (matching reads happen before the peer's photos become readable
    // under the post-match RLS); fall back to the cached candidate so a
    // refetch failure doesn't strip a URL we already had.
    final peer = await profileRepo.getProfile(peerId) ?? match.candidate;
    final url = peer.primaryPhotoUrl;
    if (url == null) return;

    final bytes = await profileRepo.getPhotoBytes(url);
    if (mounted) setState(() => _peerPhotoBytes = bytes);
  }

  void _match() async {
    final match = ref.read(activeMatchProvider);
    final self = ref.read(currentProfileProvider).asData?.value;
    if (match == null || self == null) return;

    setState(() => _stage = _Stage.waiting);

    final callId = ref.read(activeCallIdProvider);
    final revealRepo = ref.read(revealRepositoryProvider);

    // Real path: persist this user's "reveal" decision and listen for
    // the peer's via Supabase Realtime.
    if (callId != null && revealRepo != null) {
      try {
        await revealRepo.submitReveal(
          callId: callId,
          userId: self.userId,
          revealed: true,
        );
        DebugLog.reveal('reveal submitted'); // debug-observer
      } catch (e, st) {
        _log.error('submitReveal(true) failed', e, st);
      }
      _revealSub = revealRepo.watchReveals(callId).listen(
        (rows) => _onReveals(
          rows,
          callId: callId,
          self: self,
          match: match,
        ),
        onError: (e, st) => _log.error('watchReveals error', e, st),
      );
      _startRevealTimeout();
      return;
    }

    // Fallback (no Supabase / no call id): keep the demo alive with a
    // mocked peer decision so the flow is still testable offline.
    _log.warn('No callId/revealRepo — falling back to mock peer decision');
    await ref.read(matchingRepositoryProvider).recordDecision(
          self: self,
          candidate: match.candidate,
          wantsMatch: true,
        );
    _peerDecisionTimer = Timer(const Duration(milliseconds: 1600), () async {
      if (!mounted) return;
      final peerAccepts = Random().nextDouble() < 0.6;
      setState(() => _stage = peerAccepts ? _Stage.matched : _Stage.noMatch);
      if (peerAccepts) {
        await _persistMatch(self: self, match: match, callId: null);
      }
    });
  }

  /// (Re)arms the reveal-timeout timer. When it fires the waiting view
  /// surfaces "Continuer à attendre" / "Passer" so the user is never
  /// stuck waiting on a peer who has gone silent.
  void _startRevealTimeout() {
    _revealTimeoutTimer?.cancel();
    _revealTimedOut = false;
    _revealTimeoutTimer = Timer(_revealTimeout, () {
      if (!mounted || _stage != _Stage.waiting) return;
      _log.info('Reveal wait timed out — offering exit to user');
      setState(() => _revealTimedOut = true);
    });
  }

  /// "Continuer à attendre" — give the peer another full window.
  void _keepWaiting() {
    _log.info('User chose to keep waiting for the reveal');
    setState(() => _revealTimedOut = false);
    _startRevealTimeout();
  }

  /// Resolves the mutual reveal outcome from the live reveal rows.
  Future<void> _onReveals(
    List<RevealRow> rows, {
    required String callId,
    required dynamic self,
    required ActiveMatch match,
  }) async {
    if (!mounted) return;
    final repo = ref.read(revealRepositoryProvider);
    if (repo == null) return;
    final outcome = repo.outcomeFor(
      rows,
      selfId: self.userId as String,
      peerId: match.candidate.userId,
    );
    _log.info('Reveal outcome — $outcome (${rows.length} row(s))');
    switch (outcome) {
      case RevealOutcome.pending:
        // Still waiting for the peer — stay on the waiting view.
        break;
      case RevealOutcome.mutual:
        _revealTimeoutTimer?.cancel();
        DebugLog.reveal('reveal mutual'); // debug-observer
        DebugObserver.instance.setRevealOutcome('mutual');
        setState(() => _stage = _Stage.matched);
        await _persistMatch(self: self, match: match, callId: callId);
      case RevealOutcome.declined:
        _revealTimeoutTimer?.cancel();
        DebugLog.reveal('declined'); // debug-observer
        DebugObserver.instance.setRevealOutcome('declined');
        setState(() => _stage = _Stage.noMatch);
    }
  }

  /// Writes the permanent match + opens the conversation. Idempotent —
  /// `_matchPersisted` guards against the reveal stream firing twice.
  Future<void> _persistMatch({
    required dynamic self,
    required ActiveMatch match,
    required String? callId,
  }) async {
    if (_matchPersisted) return;
    _matchPersisted = true;
    final selfId = self.userId as String;

    if (callId != null) {
      final repo = ref.read(revealRepositoryProvider);
      try {
        await repo?.createMatch(
          callId: callId,
          userA: selfId,
          userB: match.candidate.userId,
          compatibilityScore: match.score.percentage,
        );
      } catch (e, st) {
        _log.error('createMatch failed', e, st);
      }
    }

    // Keep the Discover "matches" surface in sync.
    try {
      await ref.read(discoverRepositoryProvider).recordMutualMatch(
            self: self,
            candidate: match.candidate,
            score: match.score,
          );
      final sourceId = match.sourceSuggestionId;
      if (sourceId != null) {
        await ref
            .read(discoverRepositoryProvider)
            .markSuggestionMatched(sourceId);
      }
    } catch (e, st) {
      _log.error('recordMutualMatch failed (non-fatal)', e, st);
    }

    // Open the private conversation — the only place chat is created.
    try {
      await ref.read(messagingRepositoryProvider).ensureConversation(
            currentUserId: selfId,
            peer: match.candidate,
          );
    } catch (e, st) {
      _log.error('ensureConversation failed (non-fatal)', e, st);
    }
  }

  void _pass() async {
    final match = ref.read(activeMatchProvider);
    final self = ref.read(currentProfileProvider).asData?.value;
    if (match != null && self != null) {
      _log.info('Passed candidate uid=${match.candidate.userId}');
      final callId = ref.read(activeCallIdProvider);
      final revealRepo = ref.read(revealRepositoryProvider);
      if (callId != null && revealRepo != null) {
        // Record the explicit pass so the peer's screen resolves to
        // "declined" instead of waiting forever.
        try {
          await revealRepo.submitReveal(
            callId: callId,
            userId: self.userId,
            revealed: false,
          );
          DebugLog.reveal('reveal submitted (pass)'); // debug-observer
        } catch (e, st) {
          _log.error('submitReveal(false) failed', e, st);
        }
      } else {
        await ref.read(matchingRepositoryProvider).recordDecision(
              self: self,
              candidate: match.candidate,
              wantsMatch: false,
            );
      }
    }
    if (!mounted) return;
    _revealSub?.cancel();
    _revealTimeoutTimer?.cancel();
    // Reset the shared match state immediately. _findAnother also does this,
    // but resetting here guarantees no stale match leaks into a subsequent
    // flow regardless of which exit the user takes from _PassedView.
    ref.read(activeMatchProvider.notifier).state = null;
    _log.info('Matching state reset');
    setState(() => _stage = _Stage.passed);
  }

  void _backHome() {
    ref.read(activeMatchProvider.notifier).state = null;
    _log.info('Matching state reset');
    if (!mounted) return;
    context.goNamed(AppRoute.home.name);
  }

  void _findAnother() {
    ref.read(activeMatchProvider.notifier).state = null;
    _log.info('Matching state reset');
    if (!mounted) return;
    _log.info('New match flow started');
    // Use pushReplacement instead of goNamed so the matching → call →
    // post-call chain keeps a sane back stack: the cross / Annuler buttons
    // on the next MatchingScreen need a real route to pop back to.
    context.pushReplacementNamed(AppRoute.matching.name);
  }

  @override
  void dispose() {
    _peerDecisionTimer?.cancel();
    _revealTimeoutTimer?.cancel();
    _revealSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final match = ref.watch(activeMatchProvider);

    final body = switch (_stage) {
      _Stage.decide => _DecideView(
          match: match,
          revealed: _revealed,
          peerPhotoBytes: _peerPhotoBytes,
          onReveal: () => setState(() => _revealed = true),
          onMatch: _match,
          onPass: _pass,
        ),
      _Stage.waiting => _WaitingView(
          timedOut: _revealTimedOut,
          onKeepWaiting: _keepWaiting,
          onGiveUp: _pass,
        ),
      _Stage.matched => _ResolvedView(
          matched: true,
          onBackHome: _backHome,
          onFindAnother: _findAnother,
        ),
      _Stage.noMatch => _ResolvedView(
          matched: false,
          onBackHome: _backHome,
          onFindAnother: _findAnother,
        ),
      _Stage.passed => _PassedView(
          onFindAnother: _findAnother,
          onBackHome: _backHome,
        ),
    };

    return AppScaffold(
      glowIntensity: _stage == _Stage.matched ? 1.2 : 0.6,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: Text(l10n.postCallTitle),
        actions: [
          if (match != null)
            IconButton(
              tooltip:
                  Localizations.localeOf(context).languageCode == 'fr'
                      ? 'Signaler'
                      : 'Report',
              icon: const Icon(Icons.flag_outlined),
              onPressed: () => showReportSheet(
                context,
                reportedUserId: match.candidate.userId,
                reportedDisplayName: match.candidate.firstName,
              ),
            ),
        ],
      ),
      body: body,
    );
  }
}

// ---------------------------------------------------------------------------
// Stage views
// ---------------------------------------------------------------------------

class _DecideView extends StatelessWidget {
  const _DecideView({
    required this.match,
    required this.revealed,
    required this.peerPhotoBytes,
    required this.onReveal,
    required this.onMatch,
    required this.onPass,
  });

  final ActiveMatch? match;
  final bool revealed;
  final Uint8List? peerPhotoBytes;
  final VoidCallback onReveal;
  final VoidCallback onMatch;
  final VoidCallback onPass;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final candidate = match?.candidate;
    final score = match?.score;

    return Column(
      children: [
        const SizedBox(height: AppSpacing.lg),
        Text(
          l10n.postCallSubtitle,
          textAlign: TextAlign.center,
          style: AppTypography.body.copyWith(color: AppColors.textSecondary),
        ),
        const Spacer(),
        Center(
          child: _PhotoReveal(
            revealed: revealed,
            bytes: peerPhotoBytes,
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        if (candidate != null)
          Text(
            candidate.age != null
                ? '${candidate.firstName ?? '—'}, ${candidate.age}'
                : candidate.firstName ?? '—',
            style: AppTypography.h2,
          ),
        const SizedBox(height: 4),
        if (match != null)
          Text(
            '${match!.distanceKm} km',
            style:
                AppTypography.body.copyWith(color: AppColors.textSecondary),
          ),
        if (score != null) ...[
          const SizedBox(height: AppSpacing.sm),
          CompatibilityBadge(score: score),
        ],
        const Spacer(),
        if (!revealed) ...[
          AppButton(
            label: l10n.postCallReveal,
            icon: Icons.visibility_outlined,
            size: AppButtonSize.large,
            onPressed: onReveal,
          ),
        ] else ...[
          AppButton(
            label: l10n.postCallMatch,
            icon: Icons.favorite_rounded,
            size: AppButtonSize.large,
            onPressed: onMatch,
          ),
          const SizedBox(height: AppSpacing.sm),
          AppButton(
            label: l10n.postCallPass,
            variant: AppButtonVariant.secondary,
            size: AppButtonSize.large,
            onPressed: onPass,
          ),
        ],
        const SizedBox(height: AppSpacing.lg),
      ],
    );
  }
}

class _WaitingView extends StatelessWidget {
  const _WaitingView({
    required this.timedOut,
    required this.onKeepWaiting,
    required this.onGiveUp,
  });

  /// True once the reveal wait has exceeded its timeout — surfaces an
  /// explicit way out instead of an endless spinner.
  final bool timedOut;
  final VoidCallback onKeepWaiting;
  final VoidCallback onGiveUp;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(
              height: 36,
              width: 36,
              child: CircularProgressIndicator(
                strokeWidth: 2.4,
                valueColor: AlwaysStoppedAnimation(AppColors.brandPink),
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            Text(
              'Votre date réfléchit…',
              textAlign: TextAlign.center,
              style:
                  AppTypography.body.copyWith(color: AppColors.textSecondary),
            ),
            if (timedOut) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(
                'Cette personne n\'a pas encore répondu.',
                textAlign: TextAlign.center,
                style: AppTypography.caption.copyWith(
                  color: AppColors.textTertiary,
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              AppButton(
                label: 'Continuer à attendre',
                icon: Icons.hourglass_bottom_rounded,
                size: AppButtonSize.large,
                onPressed: onKeepWaiting,
              ),
              const SizedBox(height: AppSpacing.sm),
              AppButton(
                label: 'Passer',
                variant: AppButtonVariant.secondary,
                size: AppButtonSize.large,
                onPressed: onGiveUp,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ResolvedView extends StatelessWidget {
  const _ResolvedView({
    required this.matched,
    required this.onBackHome,
    required this.onFindAnother,
  });

  final bool matched;
  final VoidCallback onBackHome;
  final VoidCallback onFindAnother;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      children: [
        const Spacer(),
        Icon(
          matched ? Icons.favorite_rounded : Icons.waving_hand_rounded,
          size: 80,
          color: matched ? AppColors.brandPink : AppColors.textSecondary,
        ).animate().scale(
              duration: 500.ms,
              curve: Curves.easeOutBack,
              begin: const Offset(0.6, 0.6),
              end: const Offset(1, 1),
            ),
        const SizedBox(height: AppSpacing.lg),
        Text(
          matched ? 'C\'est réciproque ✨' : 'Pas cette fois',
          style: AppTypography.h1,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: AppSpacing.sm),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
          child: Text(
            matched ? l10n.postCallMatchedBody : l10n.postCallNoMatchBody,
            textAlign: TextAlign.center,
            style:
                AppTypography.body.copyWith(color: AppColors.textSecondary),
          ),
        ),
        const Spacer(),
        if (matched)
          AppButton(
            label: l10n.postCallBackHome,
            icon: Icons.home_rounded,
            size: AppButtonSize.large,
            onPressed: onBackHome,
          )
        else ...[
          AppButton(
            label: l10n.postCallFindAnother,
            icon: Icons.bolt_rounded,
            size: AppButtonSize.large,
            onPressed: onFindAnother,
          ),
          const SizedBox(height: AppSpacing.sm),
          AppButton(
            label: l10n.postCallBackHome,
            variant: AppButtonVariant.secondary,
            onPressed: onBackHome,
          ),
        ],
        const SizedBox(height: AppSpacing.lg),
      ],
    );
  }
}

class _PassedView extends StatelessWidget {
  const _PassedView({
    required this.onFindAnother,
    required this.onBackHome,
  });

  final VoidCallback onFindAnother;
  final VoidCallback onBackHome;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      children: [
        const Spacer(),
        const Icon(
          Icons.bolt_rounded,
          size: 72,
          color: AppColors.brandPink,
        ).animate().scale(
              duration: 500.ms,
              curve: Curves.easeOutBack,
              begin: const Offset(0.6, 0.6),
              end: const Offset(1, 1),
            ),
        const SizedBox(height: AppSpacing.lg),
        Text(
          l10n.postCallPassTitle,
          style: AppTypography.h1,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: AppSpacing.sm),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
          child: Text(
            l10n.postCallPassBody,
            textAlign: TextAlign.center,
            style:
                AppTypography.body.copyWith(color: AppColors.textSecondary),
          ),
        ),
        const Spacer(),
        AppButton(
          label: l10n.postCallFindAnother,
          icon: Icons.favorite_rounded,
          size: AppButtonSize.large,
          onPressed: onFindAnother,
        ),
        const SizedBox(height: AppSpacing.sm),
        // Secondary escape — lets the user step out of the date flow
        // entirely instead of being funnelled into another match.
        AppButton(
          label: l10n.postCallBackHome,
          icon: Icons.home_rounded,
          variant: AppButtonVariant.secondary,
          onPressed: onBackHome,
        ),
        const SizedBox(height: AppSpacing.lg),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Photo reveal — the **only** place a real photo can surface
// ---------------------------------------------------------------------------

class _PhotoReveal extends StatelessWidget {
  const _PhotoReveal({required this.revealed, required this.bytes});

  final bool revealed;
  final Uint8List? bytes;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    const size = 220.0;

    if (!revealed || bytes == null) {
      return Column(
        children: [
          Stack(
            alignment: Alignment.center,
            children: [
              const BlurredAvatar(size: size),
              if (bytes != null)
                ClipOval(
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                    child: const SizedBox(width: size, height: size),
                  ),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            l10n.hiddenPhotoLabel,
            style: AppTypography.caption.copyWith(
              color: AppColors.textTertiary,
            ),
          ),
        ],
      );
    }

    // Reveal animation — the photo "develops" from a heavy blur into
    // focus, giving the moment a beat of suspense instead of a hard cut.
    return ClipOval(
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: 26, end: 0),
        duration: const Duration(milliseconds: 1100),
        curve: Curves.easeOutCubic,
        builder: (context, sigma, child) {
          return ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
            child: child,
          );
        },
        child: Image.memory(
          bytes!,
          width: size,
          height: size,
          fit: BoxFit.cover,
        ),
      ),
    )
        .animate()
        .scale(
          duration: 520.ms,
          begin: const Offset(0.9, 0.9),
          end: const Offset(1, 1),
          curve: Curves.easeOutBack,
        )
        .fadeIn(duration: 380.ms);
  }
}
