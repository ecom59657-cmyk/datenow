import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/app_routes.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../core/config/app_config.dart';
import '../../../core/debug/debug_observer.dart';
import '../../../core/utils/extensions.dart';
import '../../../core/utils/logger.dart';
import '../../../shared/widgets/app_button.dart';
import '../../auth/presentation/providers/auth_provider.dart';
import '../../matching/presentation/providers/active_match_provider.dart';
import '../../post_call/data/reveal_repository.dart';
import '../../presence/domain/presence_status.dart';
import '../../presence/presentation/presence_controller.dart';
import '../data/call_session_repository.dart';
import 'agora_call_view.dart';

/// 5-minute live call screen — Jitsi-only.
///
/// Responsibilities reduced to:
///   1. Open (or join) the shared `calls` row in Supabase via
///      [CallSessionRepository]. The row is the source of truth for both
///      peers and powers the realtime end-of-call signal.
///   2. Build the deterministic Jitsi URL `https://meet.jit.si/datenow_<id>`
///      and let the user open it in their native browser. DateNow never
///      touches camera/mic itself.
///   3. Run the 5-minute countdown; auto-end when it hits zero.
///   4. Listen for the peer's `status='ended'` flip and tear down locally.
///   5. Push the user to the post-call screen on end.
class CallScreen extends ConsumerStatefulWidget {
  const CallScreen({super.key});

  @override
  ConsumerState<CallScreen> createState() => _CallScreenState();
}

/// Pre-call handshake phases. The Agora video only mounts at [live] — the
/// earlier phases run a calm "Connexion du date…" screen so the call
/// never appears as an abrupt black flash.
enum _PreCall { opening, waitingPeer, joining, live }

class _CallScreenState extends ConsumerState<CallScreen> {
  static const _log = AppLogger('Call');

  /// Max time to wait for the peer's ready flag before joining anyway —
  /// a peer who never readies (closed the app) must not freeze us here.
  static const _peerReadyTimeout = Duration(seconds: 15);

  /// Length of the closing "Connexion du date…" flourish before the
  /// video mounts.
  static const _joiningFlourish = Duration(milliseconds: 1300);

  /// Countdown anchor. Seeded with the local clock so the timer ticks
  /// from the moment the screen mounts, then overwritten with the call
  /// row's server `started_at` once the session opens — that makes the
  /// countdown identical on both devices and survives a re-join.
  late DateTime _start;
  Duration _remaining = AppConfig.maxCallDuration;
  Timer? _ticker;

  String? _callId;
  String? _selfUserId;
  String? _channelName;
  String _supabaseCallStatus = '—';

  _PreCall _precall = _PreCall.opening;
  Timer? _peerReadyTimer;
  Timer? _joiningTimer;

  StreamSubscription<CallSessionRow>? _sessionSub;

  bool _opened = false;
  bool _ending = false;
  bool _bootstrapFailed = false;

  @override
  void initState() {
    super.initState();
    _start = DateTime.now();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_opened) return;
      _opened = true;
      // Presence: the user is now in a date video.
      ref.read(presenceControllerProvider).setIntent(PresenceStatus.inCall);
      ref.read(precallStateProvider.notifier).state = 'opening';
      _bootstrap();
    });
  }

  Future<void> _bootstrap() async {
    final selfId = ref.read(currentUserProvider)?.id;
    final match = ref.read(activeMatchProvider);
    _selfUserId = selfId;
    _log.info(
      'Bootstrap — selfId=${selfId ?? '∅'} peer=${match?.candidate.userId ?? '∅'}',
    );

    if (selfId == null || match == null) {
      _log.error(
        'CallScreen opened without an active session — bailing.',
        null,
        null,
      );
      if (!mounted) return;
      context.showSnack(
        'Impossible de démarrer le date. Réessaie depuis Discover.',
      );
      if (context.canPop()) {
        context.pop();
      } else {
        context.goNamed(AppRoute.discover.name);
      }
      return;
    }

    final repo = ref.read(callSessionRepositoryProvider);
    if (repo == null) {
      _log.warn('Supabase unavailable — cannot open call session');
      return;
    }

    try {
      final result = await repo.open(
        meUserId: selfId,
        peerUserId: match.candidate.userId,
      );
      final session = result.row;
      if (!mounted) return;
      _callId = session.id;
      // Re-anchor the countdown on the server clock so both peers see the
      // same time-left regardless of who mounted first or device skew.
      _start = session.startedAt;
      // Publish the call id so the post-call reveal screen knows which
      // `calls` row its reveal decisions attach to.
      ref.read(activeCallIdProvider.notifier).state = session.id;
      // The DB is the single source of truth for the channel name: the
      // first peer to open the session writes `channel_name = dn_<id>`
      // and every subsequent peer reads it back unchanged. Computing it
      // client-side would risk a divergence (different prefixes, char
      // mangling, …) — using the DB value guarantees both peers join
      // exactly the same Agora room.
      final channelName = session.channelName ?? 'dn_${session.id}';
      setState(() {
        _channelName = channelName;
        _supabaseCallStatus = session.status;
      });
      _log.info(
        'Call session ${result.source} — currentUserId=$selfId '
        'targetUserId=${match.candidate.userId} '
        'callId=${session.id} channelName=$channelName',
      );
      // debug-observer — feed the test overlay with the session facts.
      DebugObserver.instance.setCall(
            callId: session.id,
            channelName: channelName,
            selfUserId: selfId,
            peerUserId: match.candidate.userId,
            startedAt: session.startedAt,
          );

      // Enter the pre-call handshake: announce we're ready, then wait
      // (briefly) for the peer before mounting the video.
      setState(() => _precall = _PreCall.waitingPeer);
      ref.read(precallStateProvider.notifier).state = 'waiting_peer_ready';
      DebugObserver.instance.setPhase('waiting_peer'); // debug-observer
      try {
        await repo.markReady(session.id);
      } catch (e, st) {
        _log.warn('markReady failed (will still join): $e\n$st');
      }
      // Safety valve — a peer who never readies (closed the app) must
      // not strand us on the connecting screen.
      _peerReadyTimer = Timer(_peerReadyTimeout, () {
        if (mounted && _precall == _PreCall.waitingPeer) {
          _log.info('Peer ready timed out — joining anyway');
          _advanceToJoining();
        }
      });

      _sessionSub = repo.watch(session.id).listen(
        (row) {
          if (!mounted) return;
          setState(() => _supabaseCallStatus = row.status);
          _log.info(
            'Realtime status — ${row.status} '
            'ready(caller=${row.callerReady} callee=${row.calleeReady})',
          );
          if (row.endedByPeer(selfId)) {
            _log.info('Call ended remotely by ${row.endedBy}');
            _endCall(remote: true);
            return;
          }
          // Both peers' CallScreens are up → start the join flourish.
          if (_precall == _PreCall.waitingPeer && row.bothReady) {
            _log.info('Both peers ready — joining call');
            _advanceToJoining();
          }
        },
        onError: (e, st) =>
            _log.error('Realtime subscription error', e, st),
      );
    } catch (e, st) {
      _log.error('Could not open call session', e, st);
      if (mounted) setState(() => _bootstrapFailed = true);
    }
  }

  /// Bails out of the pre-call screen (user tapped Annuler / Retour, or
  /// bootstrap failed). Ends the call server-side so the peer isn't left
  /// hanging, then returns home rather than to the post-call reveal.
  Future<void> _cancelPreCall() async {
    if (_ending) return;
    _ending = true;
    _log.info('Pre-call cancelled by user');
    _peerReadyTimer?.cancel();
    _joiningTimer?.cancel();
    if (_callId != null && _selfUserId != null) {
      final repo = ref.read(callSessionRepositoryProvider);
      try {
        await repo?.end(callId: _callId!, byUserId: _selfUserId!);
      } catch (e, st) {
        _log.error('Could not end call on pre-call cancel', e, st);
      }
    }
    ref.read(presenceControllerProvider).setIntent(PresenceStatus.online);
    ref.read(precallStateProvider.notifier).state = 'idle';
    ref.read(activeMatchProvider.notifier).state = null;
    if (!mounted) return;
    if (context.canPop()) {
      context.pop();
    } else {
      context.goNamed(AppRoute.home.name);
    }
  }

  /// Runs the short "Connexion du date…" flourish, then mounts the video.
  void _advanceToJoining() {
    if (_precall == _PreCall.joining || _precall == _PreCall.live) return;
    _peerReadyTimer?.cancel();
    setState(() => _precall = _PreCall.joining);
    ref.read(precallStateProvider.notifier).state = 'joining_call';
    DebugObserver.instance.setPhase('joining'); // debug-observer
    _joiningTimer = Timer(_joiningFlourish, () {
      if (!mounted) return;
      setState(() => _precall = _PreCall.live);
      ref.read(precallStateProvider.notifier).state = 'live';
      DebugObserver.instance.setPhase('live'); // debug-observer
    });
  }

  void _tick() {
    final elapsed = DateTime.now().difference(_start);
    final r = AppConfig.maxCallDuration - elapsed;
    if (r.isNegative) {
      _ticker?.cancel();
      DebugLog.call('timer end'); // debug-observer
      _endCall();
      return;
    }
    setState(() => _remaining = r);
    DebugObserver.instance.setRemaining(r.inSeconds); // debug-observer
  }

  Future<void> _endCall({bool remote = false}) async {
    if (_ending) return;
    _ending = true;
    if (!mounted) return;
    _log.info(remote ? 'Call ended remotely' : 'Call ended locally');
    // AgoraCallView's dispose() runs `client.release()` when the parent
    // widget unmounts via pushReplacementNamed, so there's nothing to
    // tear down imperatively here.
    if (!remote && _callId != null && _selfUserId != null) {
      final repo = ref.read(callSessionRepositoryProvider);
      if (repo != null) {
        try {
          await repo.end(callId: _callId!, byUserId: _selfUserId!);
        } catch (e, st) {
          _log.error('Could not flip call to ended in Supabase', e, st);
        }
      }
    }
    // Date video is over — drop presence back to plain "online".
    ref.read(presenceControllerProvider).setIntent(PresenceStatus.online);
    ref.read(precallStateProvider.notifier).state = 'ended';
    DebugObserver.instance.markEnded(); // debug-observer
    if (!mounted) return;
    context.pushReplacementNamed(AppRoute.postCall.name);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _peerReadyTimer?.cancel();
    _joiningTimer?.cancel();
    _sessionSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final match = ref.watch(activeMatchProvider);
    final candidate = match?.candidate;
    final name = candidate?.firstName ?? 'Anonymous';
    final age = candidate?.age;

    // Pre-call: a calm, branded connecting screen — no abrupt black flash,
    // no HUD over an empty video surface.
    if (_precall != _PreCall.live) {
      return AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light.copyWith(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.light,
        ),
        child: Scaffold(
          backgroundColor: AppColors.background,
          body: _ConnectingView(
            phase: _bootstrapFailed ? null : _precall,
            peerName: candidate?.firstName,
            onCancel: _cancelPreCall,
          ),
        ),
      );
    }

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light.copyWith(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
      ),
      child: Scaffold(
        backgroundColor: AppColors.background,
        resizeToAvoidBottomInset: false,
        body: Stack(
          fit: StackFit.expand,
          children: [
            // Agora UIKit takes the call from here. _precall == live
            // guarantees the channel name + call id are both set.
            (_channelName == null || _callId == null)
                ? const _LoadingHint()
                : AgoraCallView(
                    callId: _callId!,
                    channelName: _channelName!,
                    onLeave: () {
                      if (mounted && !_ending) _endCall();
                    },
                  ),

            // Top HUD — back + timer + EN DIRECT. SafeArea ensures the
            // header sits below the iPhone notch.
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.md,
                  AppSpacing.sm,
                  AppSpacing.md,
                  0,
                ),
                child: Align(
                  alignment: Alignment.topCenter,
                  child: _Header(
                    remaining: _remaining,
                    onBack: () => _endCall(),
                  ),
                ),
              ),
            ),

            // Bottom HUD — name plate + "Terminer le date" CTA, semi-
            // transparent so the Jitsi UI behind remains tap-through
            // wherever this isn't.
            Align(
              alignment: Alignment.bottomCenter,
              child: SafeArea(
                top: false,
                child: Container(
                  margin: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md,
                  ),
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.md,
                    AppSpacing.sm,
                    AppSpacing.md,
                    AppSpacing.sm,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.45),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.12),
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _NamePlate(name: name, age: age),
                      const SizedBox(height: AppSpacing.sm),
                      AppButton(
                        label: 'Terminer le date',
                        icon: Icons.call_end_rounded,
                        onPressed: () => _endCall(),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Statut Supabase : $_supabaseCallStatus',
                        style: AppTypography.caption.copyWith(
                          color: Colors.white.withValues(alpha: 0.55),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Header — back button + compact timer + LIVE pill
// ---------------------------------------------------------------------------

class _Header extends StatelessWidget {
  const _Header({required this.remaining, required this.onBack});

  final Duration remaining;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Material(
              color: Colors.transparent,
              shape: const CircleBorder(),
              child: InkWell(
                onTap: onBack,
                customBorder: const CircleBorder(),
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.black.withValues(alpha: 0.45),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.15),
                    ),
                  ),
                  alignment: Alignment.center,
                  child: const Icon(
                    Icons.chevron_left_rounded,
                    color: Colors.white,
                    size: 22,
                  ),
                ),
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: 8,
            ),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.45),
              borderRadius: AppRadius.brPill,
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.15),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.brandPink,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  remaining.toMmSs(),
                  style: AppTypography.body.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.sm + 2,
                vertical: 7,
              ),
              decoration: BoxDecoration(
                color: AppColors.online.withValues(alpha: 0.22),
                borderRadius: AppRadius.brPill,
                border: Border.all(
                  color: AppColors.online.withValues(alpha: 0.5),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppColors.online,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'EN DIRECT',
                    style: AppTypography.caption.copyWith(
                      color: AppColors.online,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Name plate
// ---------------------------------------------------------------------------

class _NamePlate extends StatelessWidget {
  const _NamePlate({required this.name, required this.age});

  final String name;
  final int? age;

  @override
  Widget build(BuildContext context) {
    final title = age != null ? '$name, $age' : name;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: AppRadius.brPill,
        border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
      ),
      child: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        softWrap: false,
        style: AppTypography.body.copyWith(
          color: Colors.white,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Loading hint while the session row is being created/fetched
// ---------------------------------------------------------------------------

class _LoadingHint extends StatelessWidget {
  const _LoadingHint();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(
          height: 28,
          width: 28,
          child: CircularProgressIndicator(
            strokeWidth: 2.5,
            valueColor: AlwaysStoppedAnimation(AppColors.brandPink),
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        Text(
          'Préparation du salon…',
          style: AppTypography.caption.copyWith(
            color: AppColors.textSecondary,
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Pre-call connecting screen — calm transition before the video mounts
// ---------------------------------------------------------------------------

/// Full-screen "Connexion du date…" experience. [phase] null signals a
/// bootstrap failure and switches the view to a non-technical error.
class _ConnectingView extends StatelessWidget {
  const _ConnectingView({
    required this.phase,
    required this.peerName,
    required this.onCancel,
  });

  final _PreCall? phase;
  final String? peerName;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    if (phase == null) {
      return _ErrorState(onCancel: onCancel);
    }
    final (title, subtitle) = switch (phase!) {
      _PreCall.opening => (
          'Préparation de votre date',
          'On installe le salon vidéo…',
        ),
      _PreCall.waitingPeer => (
          'Nous avons trouvé quelqu\'un',
          peerName != null
              ? 'On attend que $peerName se connecte…'
              : 'On attend que votre date se connecte…',
        ),
      _PreCall.joining => (
          'Connexion du date…',
          'Caméra floutée — la révélation, c\'est pour la fin ✨',
        ),
      _PreCall.live => ('', ''),
    };
    final joining = phase == _PreCall.joining;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
        child: Column(
          children: [
            const Spacer(flex: 2),
            _PulseHeart(active: joining),
            const SizedBox(height: AppSpacing.xl),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 350),
              child: Text(
                title,
                key: ValueKey(title),
                textAlign: TextAlign.center,
                style: AppTypography.h1,
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 350),
              child: Text(
                subtitle,
                key: ValueKey(subtitle),
                textAlign: TextAlign.center,
                style: AppTypography.body
                    .copyWith(color: AppColors.textSecondary),
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(
                strokeWidth: 2.4,
                valueColor: AlwaysStoppedAnimation(
                  joining ? AppColors.online : AppColors.brandPink,
                ),
              ),
            ),
            const Spacer(flex: 3),
            // Always offer an exit so the user is never trapped here.
            AppButton(
              label: 'Annuler',
              variant: AppButtonVariant.secondary,
              onPressed: onCancel,
            ),
            const SizedBox(height: AppSpacing.lg),
          ],
        ),
      ),
    );
  }
}

class _PulseHeart extends StatelessWidget {
  const _PulseHeart({required this.active});

  /// When true the heart pulses faster + glows brighter (join flourish).
  final bool active;

  @override
  Widget build(BuildContext context) {
    final core = Container(
      width: 108,
      height: 108,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: AppColors.brandGradient,
        boxShadow: [
          BoxShadow(
            color: AppColors.brandPink.withValues(alpha: active ? 0.6 : 0.4),
            blurRadius: active ? 48 : 32,
            spreadRadius: active ? 8 : 4,
          ),
        ],
      ),
      child: const Icon(Icons.favorite_rounded,
          color: Colors.white, size: 46),
    );
    return core
        .animate(onPlay: (c) => c.repeat(reverse: true))
        .scaleXY(
          duration: (active ? 700 : 1100).ms,
          begin: 1,
          end: active ? 1.12 : 1.06,
          curve: Curves.easeInOut,
        );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.onCancel});

  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
        child: Column(
          children: [
            const Spacer(flex: 2),
            const Icon(
              Icons.cloud_off_rounded,
              size: 64,
              color: AppColors.textTertiary,
            ),
            const SizedBox(height: AppSpacing.lg),
            Text(
              'Connexion impossible',
              textAlign: TextAlign.center,
              style: AppTypography.h2,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'On n\'a pas pu démarrer ce date. Vérifie ta connexion '
              'et réessaie dans un instant.',
              textAlign: TextAlign.center,
              style:
                  AppTypography.body.copyWith(color: AppColors.textSecondary),
            ),
            const Spacer(flex: 3),
            AppButton(
              label: 'Retour',
              size: AppButtonSize.large,
              onPressed: onCancel,
            ),
            const SizedBox(height: AppSpacing.lg),
          ],
        ),
      ),
    );
  }
}

