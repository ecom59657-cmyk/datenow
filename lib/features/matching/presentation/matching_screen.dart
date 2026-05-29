import 'dart:async';

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
import '../../call/data/call_session_repository.dart';
import '../../presence/data/presence_repository.dart';
import '../../presence/domain/presence_status.dart';
import '../../presence/presentation/presence_controller.dart';
import '../../profile_setup/data/profile_repository.dart';
import '../../profile_setup/domain/user_profile.dart';
import '../../profile_setup/presentation/providers/profile_provider.dart';
import '../../profile_setup/presentation/widgets/blurred_avatar.dart';
import '../data/matching_repository.dart';
import '../data/matchmaking_repository.dart';
import '../domain/active_match.dart';
import '../domain/match_score.dart';
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
  // Tag intentionally explicit so a TestFlight log dump can grep for
  // `[MATCHING V1]` and immediately know which engine the user was on.
  // The future v2 driver will use the tag `[MATCHING V2]` so both
  // versions are diff-able in the same log stream.
  static const _log = AppLogger('MATCHING V1');
  // Only the two *search* messages loop here. "Confirmation du match…"
  // belongs to the `found` phase — it must never show while still
  // searching, so it is not part of this rotation.
  static const _stepCount = 2;

  Timer? _messageRotator;
  Timer? _navTimer;
  Timer? _pollTimer;
  Timer? _heartbeatTimer;
  StreamSubscription<CallSessionRow?>? _callSub;
  int _step = 0;

  _Phase _phase = _Phase.searching;
  ActiveMatch? _match;

  /// Approximate count of other reachable profiles — drives the "X profils
  /// actifs" reassurance line. Null until the first fetch lands.
  int? _activeCount;

  /// Guards against overlapping poll cycles and double-claims.
  bool _resolving = false;

  /// Wall-clock instant when [joinQueue] returned successfully. Used to
  /// stamp the time-in-queue duration on every meaningful transition
  /// (matched, empty, cancelled) — handy when reading a TestFlight log
  /// dump to know whether a "no match" report came after 5 s or 5 min.
  DateTime? _queueEnteredAt;

  /// Dispose-safe cached handles. Populated during the initial
  /// synchronous build paths (`_startSearch`, `_enterQueueAndSearch`)
  /// where `ref.read(...)` is legal, and consumed in [dispose] /
  /// [_leaveQueueBestEffort] where it ISN'T : after the framework
  /// starts unmounting, any `ref.read` throws
  /// `Bad state: Cannot use "ref" after the widget was disposed`.
  /// This was the actual crash observed on TestFlight before any
  /// `[MATCHING V1]` log could fire — the dispose teardown threw,
  /// killing the matching screen before the user had a chance to tap
  /// « Trouver un date ».
  MatchmakingRepository? _disposeRepo;
  String? _disposeUserId;
  PresenceController? _disposePresence;

  @override
  void initState() {
    super.initState();
    _startSearch();
  }

  void _startSearch() {
    _log.info('Match flow started — entering matchmaking queue');
    // Tell the world we're actively searching — feeds the peers' active
    // count and the Debug presence panel. Cache the controller for
    // dispose-safe access (see field doc on _disposePresence).
    final presence = ref.read(presenceControllerProvider);
    _disposePresence = presence;
    presence.setIntent(PresenceStatus.searching);
    DebugObserver.instance.startSession(); // debug-observer
    setState(() {
      _phase = _Phase.searching;
      _step = 0;
      _match = null;
    });
    // Looping ripple animation — purely cosmetic; the real search is the
    // poll timer below.
    _messageRotator?.cancel();
    _messageRotator = Timer.periodic(
      const Duration(seconds: 1, milliseconds: 200),
      (timer) {
        if (!mounted) {
          timer.cancel();
          return;
        }
        setState(() => _step = (_step + 1) % _stepCount);
      },
    );
    unawaited(_enterQueueAndSearch());
  }

  Future<void> _enterQueueAndSearch() async {
    final repo = ref.read(matchmakingRepositoryProvider);
    final self = ref.read(currentProfileProvider).asData?.value;
    if (repo == null || self == null) {
      _log.warn(
        'Matchmaking unavailable — supabase=${repo != null} '
        'profile=${self != null}',
      );
      if (mounted) setState(() => _phase = _Phase.empty);
      return;
    }

    // Cache for dispose-safe cleanup (see field doc on _disposeRepo).
    _disposeRepo = repo;
    _disposeUserId = self.userId;

    // Step A — INSERT row in matchmaking_queue.
    try {
      await repo.joinQueue(self.userId);
    } catch (e, st) {
      _log.error('STEP A joinQueue THREW — pas de row en queue', e, st);
      if (mounted) setState(() => _phase = _Phase.empty);
      return;
    }

    // Step A.bis — VERIFICATION : the row must actually exist server-side.
    // Catches the silent-RLS-refusal case (upsert returns null) AND the
    // case where a sweep / trigger deletes the row in the same tick.
    try {
      final row = await repo.selfQueueRow(self.userId);
      if (row == null) {
        _log.error(
          'STEP A.bis VERIFY — row NOT FOUND immediately after upsert. '
          'Soit RLS a refusé silently (sessionUid != self.userId), '
          'soit un trigger/sweep a delete la row tout de suite. '
          'Cf logs joinQueue UPSERT au-dessus pour le détail.',
        );
        if (mounted) setState(() => _phase = _Phase.empty);
        return;
      }
    } catch (e, st) {
      _log.error('STEP A.bis VERIFY THREW', e, st);
    }

    // Step B — Initial heartbeat. An upsert on a re-tap keeps the old
    // (possibly stale) heartbeat_at, so prime it now instead of waiting
    // up to 12 s for the first timer tick.
    try {
      await repo.heartbeat();
    } catch (e, st) {
      _log.error(
        'STEP B initial heartbeat THREW — row peut-être déjà swept. '
        'Le timer reprendra dans 12s.',
        e,
        st,
      );
      // Non-fatal : on continue le flow. Le timer essaiera de nouveau.
    }

    _queueEnteredAt = DateTime.now();
    _log.info('joined queue ok — clock started at ${_queueEnteredAt!.toIso8601String()}');

    // Realtime: catch the case where a *peer* claims this user first.
    _callSub = repo.watchMyActiveCall(self.userId).listen(
      _onRealtimeCall,
      onError: (e, st) => _log.error('watchMyActiveCall error', e, st),
    );

    // Heartbeat: keep the queue row fresh so peers see us as active.
    // A crash / background kills this timer → the row goes stale → we
    // drop out of everyone's candidate list within 30 s.
    _heartbeatTimer = Timer.periodic(
      const Duration(seconds: 12),
      (_) => unawaited(_heartbeat(repo)),
    );

    // Active search: poll the queue, score peers, claim the best ≥75 %.
    _pollTimer = Timer.periodic(
      const Duration(milliseconds: 2500),
      (_) => _poll(),
    );
    unawaited(_poll());
    unawaited(_refreshActiveCount());
  }

  Future<void> _heartbeat(MatchmakingRepository repo) async {
    if (!mounted || _match != null) return;
    try {
      await repo.heartbeat();
    } catch (e) {
      _log.warn('queue heartbeat failed (will retry): $e');
    }
    await _refreshActiveCount();
  }

  /// Refreshes the "X profils actifs" reassurance figure. Best-effort —
  /// a failure just leaves the previous value (or the generic copy).
  Future<void> _refreshActiveCount() async {
    final presence = ref.read(presenceRepositoryProvider);
    if (presence == null || !mounted || _match != null) return;
    final count = await presence.activeProfilesCount();
    if (!mounted || count == null) return;
    setState(() => _activeCount = count);
  }

  /// Single poll tick. Calls the server-side
  /// `find_best_live_candidate_v1` RPC (real PostGIS distance + hard
  /// gates + scoring), claims the best match if any, and logs the
  /// rejection reason otherwise so a tester can diagnose a "no match"
  /// from the console alone.
  Future<void> _poll() async {
    if (_resolving || _match != null || !mounted) return;
    _resolving = true;
    try {
      final repo = ref.read(matchmakingRepositoryProvider);
      final profiles = ref.read(profileRepositoryProvider);
      final self = ref.read(currentProfileProvider).asData?.value;
      if (repo == null || self == null) return;

      final result = await repo.findBestLiveCandidateV1(
        selfId: self.userId,
        // Threshold tuned for tonight's test — the v3 plan (sub-phase
        // 1.5) replaces this with the freshness-decay state machine.
        minScore: 50,
      );

      if (result.candidateId == null) {
        // The repo already logged the structured reason. Surfacing the
        // poll-level summary helps spot pattern across ticks (e.g.
        // "queue_empty x 5 polls in a row").
        _log.info(
          'poll — no match — '
          'reason=${result.rejectionReason} '
          'queue=${result.queueSize} eligible=${result.candidatesEvaluated}',
        );
        return;
      }

      final candidateId = result.candidateId!;
      final peer = await profiles.getProfile(candidateId);
      if (peer == null) {
        _log.warn(
          'poll — RPC chose $candidateId but profile fetch returned null',
        );
        return;
      }

      _log.info(
        'poll — claiming ${peer.userId} score=${result.totalScore}/100 '
        'dist=${result.distanceM}m',
      );
      final session = await repo.claimMatch(peer.userId);
      if (!mounted) return;
      _onMatched(
        session,
        peer,
        MatchScore(
          percentage: result.totalScore ?? 0,
          breakdown: <String, int>{
            'distance': result.scoreDistance ?? 0,
            'interests': result.scoreInterests ?? 0,
            'age': result.scoreAge ?? 0,
            'freshness': result.scoreFreshness ?? 0,
          },
        ),
        distanceKm: ((result.distanceM ?? 0) / 1000).round(),
      );
    } catch (e, st) {
      _log.warn('poll attempt failed (will retry): $e\n$st');
    } finally {
      _resolving = false;
    }
  }

  /// Fires when Supabase Realtime reports a `calls` row where this user
  /// is a participant — i.e. a peer ran `claim_match` against us.
  Future<void> _onRealtimeCall(CallSessionRow? session) async {
    if (session == null || _match != null || !mounted) return;
    final self = ref.read(currentProfileProvider).asData?.value;
    if (self == null) return;
    final peerId = session.callerId == self.userId
        ? session.calleeId
        : session.callerId;
    _log.info(
      'Realtime — paired via session ${session.id}, peer=$peerId',
    );
    final peer = await ref.read(profileRepositoryProvider).getProfile(peerId);
    if (peer == null || !mounted || _match != null) return;
    // Passive side: peer ran claim_match against us, so the match
    // already exists. We don't have the distance breakdown here (only
    // the active side does). Show a generic score above the floor so
    // the UI doesn't render a misleading "0%". Sub-phase 1.5 will
    // either denormalise distance_m onto the `calls` row or expose a
    // distance_between_users RPC.
    const score = MatchScore(
      percentage: 75,
      breakdown: <String, int>{},
    );
    _onMatched(session, peer, score);
  }

  void _onMatched(
    CallSessionRow session,
    UserProfile peer,
    MatchScore score, {
    int distanceKm = 0,
  }) {
    if (_match != null) return;
    final waitedMs = _queueEnteredAt != null
        ? DateTime.now().difference(_queueEnteredAt!).inMilliseconds
        : null;
    _log.info(
      'Matched! peer=${peer.userId} score=${score.percentage}% '
      'session=${session.id} dist=${distanceKm}km '
      'waited=${waitedMs ?? '?'}ms',
    );
    _pollTimer?.cancel();
    _heartbeatTimer?.cancel();
    _messageRotator?.cancel();
    _callSub?.cancel();
    final match = ActiveMatch(
      candidate: peer,
      distanceKm: distanceKm,
      score: score,
    );
    setState(() {
      _match = match;
      _phase = _Phase.found;
    });
    DebugObserver.instance.setPhase('matched'); // debug-observer
    ref.read(activeMatchProvider.notifier).state = match;
    _navTimer = Timer(const Duration(milliseconds: 1600), _goToCall);
  }

  void _goToCall() {
    if (!mounted) return;
    final peer = ref.read(activeMatchProvider)?.candidate.userId;
    _log.info('Navigating to CallScreen — peer=${peer ?? '∅'}');
    context.pushReplacementNamed(AppRoute.call.name);
  }

  /// Fire-and-forget queue exit so a cancelled / disposed search frees
  /// the user's slot for future matches.
  ///
  /// Reads from the cached fields ([_disposeRepo], [_disposeUserId])
  /// rather than `ref` — this method is called from [dispose] where
  /// `ref.read` throws once the unmount has started.
  void _leaveQueueBestEffort() {
    final repo = _disposeRepo;
    final selfId = _disposeUserId;
    if (repo != null && selfId != null) {
      unawaited(repo.leaveQueue(selfId));
    }
  }

  void _cancel() {
    _log.info('Match flow cancelled');
    _messageRotator?.cancel();
    _navTimer?.cancel();
    _pollTimer?.cancel();
    _heartbeatTimer?.cancel();
    _callSub?.cancel();
    _leaveQueueBestEffort();
    // No longer searching — drop back to plain "online".
    ref.read(presenceControllerProvider).setIntent(PresenceStatus.online);
    ref.read(activeMatchProvider.notifier).state = null;
    _log.info('Matching state reset');
    _log.info('Navigating back after cancel');
    if (context.canPop()) {
      context.pop();
    } else {
      context.goNamed(AppRoute.home.name);
    }
  }

  @override
  void dispose() {
    _messageRotator?.cancel();
    _navTimer?.cancel();
    _pollTimer?.cancel();
    _heartbeatTimer?.cancel();
    _callSub?.cancel();
    // Only leave the queue if we didn't match — a match already removed
    // both users server-side, and we want to keep the user reachable if
    // they navigated to the call screen.
    if (_match == null) {
      _leaveQueueBestEffort();
      // `ref.read` would throw here — use the cached controller instead.
      _disposePresence?.setIntent(PresenceStatus.online);
    }
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
        _Phase.searching => _SearchingView(
            l10n: l10n,
            step: _step,
            activeCount: _activeCount,
            onCancel: _cancel,
          ),
        _Phase.found => _FoundView(l10n: l10n, match: _match!),
        _Phase.empty => _EmptyView(
            l10n: l10n,
            onRetry: _startSearch,
            onCancel: _cancel,
          ),
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Searching
// ---------------------------------------------------------------------------

class _SearchingView extends StatelessWidget {
  const _SearchingView({
    required this.l10n,
    required this.step,
    required this.activeCount,
    required this.onCancel,
  });

  final AppLocalizations l10n;
  final int step;
  final int? activeCount;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    // Only the two search-phase messages. "Confirmation du match…"
    // (matchingStep3) is deliberately NOT here — it belongs to the
    // `found` phase, once a compatible peer has actually been detected.
    final messages = [
      l10n.matchingStep1,
      l10n.matchingStep2,
    ];
    final index = step % messages.length;
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
            messages[index],
            key: ValueKey(index),
            textAlign: TextAlign.center,
            style: AppTypography.body.copyWith(
              color: AppColors.textSecondary,
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        _ActivePulse(count: activeCount),
        const Spacer(flex: 3),
        AppButton(
          label: l10n.cancel,
          variant: AppButtonVariant.secondary,
          onPressed: onCancel,
        ),
        const SizedBox(height: AppSpacing.lg),
      ],
    );
  }
}

/// A soft "the app is alive" reassurance pill — a pulsing dot plus the
/// approximate number of reachable profiles. Falls back to a generic
/// line until the first count lands so it never shows "0".
class _ActivePulse extends StatelessWidget {
  const _ActivePulse({required this.count});

  final int? count;

  @override
  Widget build(BuildContext context) {
    final label = (count == null || count! <= 0)
        ? 'Communauté active en ce moment'
        : '≈ $count ${count == 1 ? 'profil actif' : 'profils actifs'} '
            'en ce moment';
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: 8,
        ),
        decoration: BoxDecoration(
          color: AppColors.online.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppColors.online.withValues(alpha: 0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.online,
              ),
            )
                .animate(onPlay: (c) => c.repeat(reverse: true))
                .fadeIn(duration: 900.ms)
                .then()
                .fadeOut(duration: 900.ms),
            const SizedBox(width: 8),
            Text(
              label,
              style: AppTypography.caption.copyWith(
                color: AppColors.online,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
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
          // Shown ONLY here, in the `found` phase — a compatible peer has
          // really been detected and the call is being confirmed.
          l10n.matchingStep3,
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
  const _EmptyView({
    required this.l10n,
    required this.onRetry,
    required this.onCancel,
  });

  final AppLocalizations l10n;
  final VoidCallback onRetry;
  final VoidCallback onCancel;

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
          onPressed: onCancel,
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
