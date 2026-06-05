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
import '../data/matching_driver.dart';
import '../data/matching_driver_provider.dart';
import '../data/matching_repository.dart';
import '../domain/active_match.dart';
import '../domain/match_score.dart';
import 'matching_cleanup_controller.dart';
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

/// Bounded search state machine. searching/widening/finalCheck are the three
/// time-based stages of the SAME active search (poll + heartbeat keep running);
/// they only change the on-screen copy and (gently) the score floor. found →
/// call. noDateAvailable → the clean 30 s give-up. error → a setup/network
/// failure (never masked as "no date").
enum _Phase { searching, widening, finalCheck, found, noDateAvailable, error }

class _MatchingScreenState extends ConsumerState<MatchingScreen>
    with WidgetsBindingObserver {
  // Tag intentionally explicit so a TestFlight log dump can grep for
  // `[MATCHING V1]` and immediately know which engine the user was on.
  // The future v2 driver will use the tag `[MATCHING V2]` so both
  // versions are diff-able in the same log stream.
  static const _log = AppLogger('MATCHING V1');

  /// Bounded search: the copy (and score floor) progress with elapsed time and
  /// the whole search is hard-capped so the user never waits on an endless
  /// spinner.
  ///   0-8s   searching   (minScore 50)
  ///   8-18s  widening    (minScore 45)
  ///   18-30s finalCheck  (minScore 40)
  ///   >30s   noDateAvailable — give up cleanly.
  static const _widenAfter = Duration(seconds: 8);
  static const _finalCheckAfter = Duration(seconds: 18);
  static const _searchTimeout = Duration(seconds: 30);

  Timer? _searchTimer;
  Timer? _navTimer;
  Timer? _pollTimer;
  Timer? _heartbeatTimer;
  StreamSubscription<CallSessionRow?>? _callSub;

  /// Wall-clock instant the current search began — drives the stage copy and
  /// the 30 s cap. Reset on every (re)search.
  DateTime? _searchStart;

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
  /// The active matching driver — V1 today (default flag OFF), V2-with-V1-fallback
  /// when `FeatureFlags.useMatchingV2` is flipped. Cached on the
  /// dispose-safe path so teardown can `leaveQueue` without `ref.read`.
  MatchingDriver? _disposeDriver;
  String? _disposeUserId;
  PresenceController? _disposePresence;

  /// Owns the "already-left-queue" flag so the three exit paths
  /// (cancel button, framework dispose, app-pause / detached) cannot
  /// stack duplicate `leaveQueue` + `setIntent(online)` calls. Built
  /// once in [initState] with closures over the cached dispose-safe
  /// handles — the closures read at call-time so a teardown firing
  /// BEFORE `_enterQueueAndSearch` populated the handles is a clean
  /// no-op. Pure-Dart class, unit-tested in
  /// `test/matching_cleanup_controller_test.dart`.
  late final MatchingCleanupController _cleanup;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _cleanup = MatchingCleanupController(
      leaveQueue: () async {
        final driver = _disposeDriver;
        final selfId = _disposeUserId;
        if (driver != null && selfId != null) {
          await driver.leaveQueue(selfId);
        }
      },
      resetPresence: () {
        _disposePresence?.setIntent(PresenceStatus.online);
      },
      logger: (msg) => _log.info(msg),
    );
    _startSearch();
  }

  /// Single source of truth for "stop everything that ticks". Used by
  /// every exit path so a future timer added to the search loop only
  /// has to be cancelled here once.
  void _cancelAllTimers() {
    _searchTimer?.cancel();
    _navTimer?.cancel();
    _pollTimer?.cancel();
    _heartbeatTimer?.cancel();
    _callSub?.cancel();
  }

  /// Lifecycle gate for Cas 3 (app backgrounded mid-search). On
  /// `paused` / `detached` the device may suspend the Dart isolate
  /// indefinitely; we proactively drop out of the queue + cancel
  /// timers so the row goes stale immediately rather than waiting
  /// for the server-side sweep (30 s heartbeat window + 60 s cron).
  /// Resume UX after a pause is intentionally degraded — the screen
  /// keeps its searching visuals but the queue row is gone, so the
  /// user has to tap cancel + retry to re-enter. Documented trade-off.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _log.info(
        'App lifecycle = ${state.name} — exiting queue best-effort',
      );
      _cancelAllTimers();
      unawaited(
        _cleanup.run(
          matched: _match != null,
          trigger: 'lifecycle:${state.name}',
        ),
      );
    }
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
    _searchStart = DateTime.now();
    setState(() {
      _phase = _Phase.searching;
      _match = null;
    });
    // Drives the searching → widening → finalCheck → noDateAvailable
    // progression purely from elapsed time. The real search is the poll
    // timer started in _enterQueueAndSearch.
    _searchTimer?.cancel();
    _searchTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _tickSearch(),
    );
    unawaited(_enterQueueAndSearch());
  }

  /// One stage tick. Advances the copy with elapsed time and gives up cleanly
  /// at [_searchTimeout]. No-op once a match landed.
  void _tickSearch() {
    if (!mounted || _match != null) return;
    final start = _searchStart;
    if (start == null) return;
    final elapsed = DateTime.now().difference(start);
    if (elapsed >= _searchTimeout) {
      _onSearchTimedOut();
      return;
    }
    final next = elapsed >= _finalCheckAfter
        ? _Phase.finalCheck
        : elapsed >= _widenAfter
            ? _Phase.widening
            : _Phase.searching;
    if (next != _phase) setState(() => _phase = next);
  }

  /// 30 s elapsed with no match → stop everything, leave the queue cleanly and
  /// show the explicit "no date available" state. Never an endless spinner.
  void _onSearchTimedOut() {
    if (_match != null) return;
    final waitedMs = _queueEnteredAt != null
        ? DateTime.now().difference(_queueEnteredAt!).inMilliseconds
        : null;
    _log.info(
      'search timed out at ${_searchTimeout.inSeconds}s — no date available '
      '(waited=${waitedMs ?? '?'}ms)',
    );
    _cancelAllTimers();
    // Leave the queue directly — NOT via _cleanup, which is one-shot and must
    // stay available for the eventual real exit AND for a Réessayer re-entry.
    unawaited(_leaveQueueSilently());
    _disposePresence?.setIntent(PresenceStatus.online);
    if (mounted) setState(() => _phase = _Phase.noDateAvailable);
  }

  Future<void> _leaveQueueSilently() async {
    final driver = _disposeDriver;
    final selfId = _disposeUserId;
    if (driver == null || selfId == null) return;
    try {
      await driver.leaveQueue(selfId);
    } catch (e) {
      _log.warn('leaveQueue (timeout) failed (ignored): $e');
    }
  }

  Future<void> _enterQueueAndSearch() async {
    final driver = ref.read(matchingDriverProvider);
    final self = ref.read(currentProfileProvider).asData?.value;
    if (driver == null || self == null) {
      _log.warn(
        'Matchmaking unavailable — driver=${driver != null} '
        'profile=${self != null}',
      );
      if (mounted) setState(() => _phase = _Phase.error);
      return;
    }
    _log.info('Using driver=${driver.name}');

    // Cache for dispose-safe cleanup (see field doc on _disposeDriver).
    _disposeDriver = driver;
    _disposeUserId = self.userId;

    // Step A — INSERT row in matchmaking_queue.
    try {
      await driver.joinQueue(self.userId);
    } catch (e, st) {
      _log.error('STEP A joinQueue THREW — pas de row en queue', e, st);
      if (mounted) setState(() => _phase = _Phase.error);
      return;
    }

    // Step A.bis — VERIFICATION : the row must actually exist server-side.
    // Catches the silent-RLS-refusal case (upsert returns null) AND the
    // case where a sweep / trigger deletes the row in the same tick.
    // V2 returns a synthetic confirmation (the Edge Function already
    // validated server-side) so this branch always passes there.
    try {
      final row = await driver.selfQueueRow(self.userId);
      if (row == null) {
        _log.error(
          'STEP A.bis VERIFY — row NOT FOUND immediately after upsert. '
          'Soit RLS a refusé silently (sessionUid != self.userId), '
          'soit un trigger/sweep a delete la row tout de suite. '
          'Cf logs joinQueue UPSERT au-dessus pour le détail.',
        );
        if (mounted) setState(() => _phase = _Phase.error);
        return;
      }
    } catch (e, st) {
      _log.error('STEP A.bis VERIFY THREW', e, st);
    }

    // Step B — Initial heartbeat. An upsert on a re-tap keeps the old
    // (possibly stale) heartbeat_at, so prime it now instead of waiting
    // up to 12 s for the first timer tick.
    try {
      await driver.heartbeat();
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
    _callSub = driver.watchMyActiveCall(self.userId).listen(
      _onRealtimeCall,
      onError: (e, st) => _log.error('watchMyActiveCall error', e, st),
    );

    // Heartbeat: keep the queue row fresh so peers see us as active.
    // A crash / background kills this timer → the row goes stale → we
    // drop out of everyone's candidate list within 30 s.
    _heartbeatTimer = Timer.periodic(
      const Duration(seconds: 12),
      (_) => unawaited(_heartbeat(driver)),
    );

    // Active search: poll the queue, score peers, claim the best ≥75 %.
    _pollTimer = Timer.periodic(
      const Duration(milliseconds: 2500),
      (_) => _poll(),
    );
    unawaited(_poll());
    unawaited(_refreshActiveCount());
  }

  Future<void> _heartbeat(MatchingDriver driver) async {
    if (!mounted || _match != null) return;
    try {
      await driver.heartbeat();
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
      final driver = ref.read(matchingDriverProvider);
      final profiles = ref.read(profileRepositoryProvider);
      final self = ref.read(currentProfileProvider).asData?.value;
      if (driver == null || self == null) return;

      // Gently widen the compatibility floor as the search progresses
      // (50 → 45 → 40). The RPC's hard gates (identity, distance cap,
      // not-self / not-banned) are unchanged, so this never surfaces a false
      // match — only a slightly lower score floor.
      final minScore = switch (_phase) {
        _Phase.finalCheck => 40,
        _Phase.widening => 45,
        _ => 50,
      };
      final result = await driver.findBestLiveCandidateV1(
        selfId: self.userId,
        minScore: minScore,
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

      // Defensive guard right before the only mutating server call in
      // this poll. Without it, a screen disposed between the candidate
      // fetch and claim_match would still create a `calls` row — the
      // peer gets paged into a ghost call this client never opens.
      // `_cleanup.hasRun` also covers the lifecycle-pause case where
      // we already left the queue but a poll Future was already in
      // flight when `paused` fired.
      if (!mounted || _cleanup.hasRun) return;

      _log.info(
        'poll — claiming ${peer.userId} score=${result.totalScore}/100 '
        'dist=${result.distanceM}m',
      );
      final session = await driver.claimMatch(peer.userId);
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
    _searchTimer?.cancel();
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

  void _cancel() {
    _log.info('Match flow cancelled');
    _cancelAllTimers();
    // Idempotent — if a lifecycle pause already triggered teardown
    // this is a no-op. Otherwise it flips `_cleanup.hasRun` and the
    // imminent `dispose()` is also a no-op.
    unawaited(_cleanup.run(matched: _match != null, trigger: 'cancel'));
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
    WidgetsBinding.instance.removeObserver(this);
    _cancelAllTimers();
    // Idempotent and matched-aware (see MatchingCleanupController).
    // `unawaited` because dispose is synchronous — the `_ran` flag
    // flips before the first `await` inside `run()`, so subsequent
    // calls within the same tick already see it as run.
    unawaited(_cleanup.run(matched: _match != null, trigger: 'dispose'));
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
        _Phase.searching || _Phase.widening || _Phase.finalCheck =>
          _SearchingView(
            l10n: l10n,
            phase: _phase,
            activeCount: _activeCount,
            onCancel: _cancel,
          ),
        _Phase.found => _FoundView(l10n: l10n, match: _match!),
        _Phase.noDateAvailable => _NoDateView(
            onRetry: _startSearch,
            onCancel: _cancel,
          ),
        _Phase.error => _ErrorView(
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
    required this.phase,
    required this.activeCount,
    required this.onCancel,
  });

  final AppLocalizations l10n;
  final _Phase phase;
  final int? activeCount;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    // Stage-driven copy — progresses with elapsed time so the search reads as
    // active and bounded, never a static loop.
    final (String title, String subtitle) = switch (phase) {
      _Phase.widening => (
          'On élargit légèrement la recherche…',
          'On regarde les profils compatibles un peu plus loin.',
        ),
      _Phase.finalCheck => (
          'Dernière vérification…',
          'On essaie de trouver quelqu\'un prêt pour un date maintenant.',
        ),
      _ => (
          'Recherche d\'une personne disponible…',
          'On vérifie les profils compatibles en ligne.',
        ),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Spacer(flex: 2),
        const Center(child: _RippleAvatar()),
        const SizedBox(height: AppSpacing.xl),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          child: Text(
            title,
            key: ValueKey(title),
            textAlign: TextAlign.center,
            style: AppTypography.h2,
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          child: Text(
            subtitle,
            key: ValueKey(subtitle),
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
// Terminal states — no date after 30 s, or a setup/network error
// ---------------------------------------------------------------------------

/// Shared layout for the two terminal states: icon + title + body + the two
/// "Réessayer" / "Retour à l'accueil" actions.
class _TerminalView extends StatelessWidget {
  const _TerminalView({
    required this.icon,
    required this.title,
    required this.body,
    required this.onRetry,
    required this.onCancel,
  });

  final IconData icon;
  final String title;
  final String body;
  final VoidCallback onRetry;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Spacer(flex: 2),
        Icon(icon, size: 64, color: AppColors.textTertiary),
        const SizedBox(height: AppSpacing.lg),
        Text(title, textAlign: TextAlign.center, style: AppTypography.h2),
        const SizedBox(height: AppSpacing.sm),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
          child: Text(
            body,
            textAlign: TextAlign.center,
            style: AppTypography.body.copyWith(color: AppColors.textSecondary),
          ),
        ),
        const Spacer(flex: 3),
        AppButton(
          label: 'Réessayer',
          size: AppButtonSize.large,
          onPressed: onRetry,
        ),
        const SizedBox(height: AppSpacing.sm),
        AppButton(
          label: 'Retour à l\'accueil',
          variant: AppButtonVariant.secondary,
          onPressed: onCancel,
        ),
        const SizedBox(height: AppSpacing.lg),
      ],
    );
  }
}

/// 30 s elapsed without a date — the bounded give-up state.
class _NoDateView extends StatelessWidget {
  const _NoDateView({required this.onRetry, required this.onCancel});

  final VoidCallback onRetry;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return _TerminalView(
      icon: Icons.hourglass_empty_rounded,
      title: 'Aucun date disponible pour le moment.',
      body: 'Reviens dans quelques minutes ou relance une recherche.',
      onRetry: onRetry,
      onCancel: onCancel,
    );
  }
}

/// Setup / network failure — never masked as "no date available".
class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.onRetry, required this.onCancel});

  final VoidCallback onRetry;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return _TerminalView(
      icon: Icons.cloud_off_rounded,
      title: 'Connexion impossible',
      body: 'Vérifie ta connexion et réessaie.',
      onRetry: onRetry,
      onCancel: onCancel,
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
