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

  /// Handle exposed by [AgoraCallView] so we can stop the engine BEFORE
  /// pushing the post-call screen. Without this, the peer's audio kept
  /// playing on the reveal UI for a second or two while the platform-
  /// side teardown raced the route push.
  AgoraCallController? _agoraController;

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
      setState(() => _channelName = channelName);
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

    // 1. Hard-stop the Agora engine BEFORE we navigate. Without this,
    //    `release()` runs asynchronously from AgoraCallView's dispose
    //    and the peer's audio can keep playing on top of the post-call
    //    screen for a second or two. stopEngine() is idempotent — the
    //    dispose-time call later is a safe no-op.
    final agora = _agoraController;
    if (agora != null) {
      try {
        await agora.stopEngine();
      } catch (e, st) {
        _log.warn('stopEngine threw (will continue tearing down): $e\n$st');
      }
    }

    // 2. Flip the Supabase call row to `ended` so the peer's listener
    //    fires (and the server-side cleanup proceeds). Skip if WE ended
    //    in response to the peer doing it — the row is already `ended`.
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
                    onControllerCreated: (controller) {
                      _agoraController = controller;
                    },
                  ),

            // Top HUD — compact row: peer pill · timer · LIVE pill.
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
                    name: name,
                    age: age,
                    remaining: _remaining,
                  ),
                ),
              ),
            ),

            // Bottom HUD — a single row of 4 compact circular controls
            // (mic / cam / switch / end). No big translucent panel; the
            // video gets the full screen. AnimatedBuilder rebuilds only
            // when the controller's mic/cam state changes.
            Align(
              alignment: Alignment.bottomCenter,
              child: SafeArea(
                top: false,
                minimum: const EdgeInsets.only(bottom: AppSpacing.sm),
                child: AnimatedBuilder(
                  animation: _agoraController ?? const _NullListenable(),
                  builder: (context, _) {
                    final c = _agoraController;
                    final ready = c?.isReady ?? false;
                    return _ControlBar(
                      micMuted: c?.micMuted ?? false,
                      cameraOff: c?.cameraOff ?? false,
                      enabled: ready,
                      onToggleMic: () => c?.toggleMic(),
                      onToggleCamera: () => c?.toggleCamera(),
                      onSwitchCamera: () => c?.switchCamera(),
                      onEnd: () => _endCall(),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A no-op Listenable so [AnimatedBuilder] can mount before the Agora
/// controller is wired. Once the parent stores the real controller and
/// rebuilds, AnimatedBuilder swaps to it and starts listening.
class _NullListenable extends Listenable {
  const _NullListenable();
  @override
  void addListener(VoidCallback listener) {}
  @override
  void removeListener(VoidCallback listener) {}
}

// ---------------------------------------------------------------------------
// Header — back button + compact timer + LIVE pill
// ---------------------------------------------------------------------------

/// Compact top HUD row: peer name pill · live timer · "EN DIRECT" badge.
/// One line, ~44 dp tall — designed to sit under the notch without
/// fighting with the video.
class _Header extends StatelessWidget {
  const _Header({
    required this.name,
    required this.age,
    required this.remaining,
  });

  final String name;
  final int? age;
  final Duration remaining;

  @override
  Widget build(BuildContext context) {
    final peerLabel = age != null ? '$name, $age' : name;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Flexible(child: _peerPill(peerLabel)),
        const SizedBox(width: AppSpacing.sm),
        _timerPill(),
        const SizedBox(width: AppSpacing.sm),
        _livePill(),
      ],
    );
  }

  Widget _peerPill(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        borderRadius: AppRadius.brPill,
        border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.person_rounded, size: 14, color: Colors.white),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              softWrap: false,
              style: AppTypography.caption.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _timerPill() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        borderRadius: AppRadius.brPill,
        border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
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
            style: AppTypography.caption.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _livePill() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: AppColors.online.withValues(alpha: 0.22),
        borderRadius: AppRadius.brPill,
        border: Border.all(color: AppColors.online.withValues(alpha: 0.5)),
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
          const SizedBox(width: 5),
          Text(
            'LIVE',
            style: AppTypography.caption.copyWith(
              color: AppColors.online,
              fontWeight: FontWeight.w800,
              letterSpacing: 1,
              fontSize: 10,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Bottom control bar — 4 compact circular buttons (mic / cam / switch / end)
// ---------------------------------------------------------------------------

class _ControlBar extends StatelessWidget {
  const _ControlBar({
    required this.micMuted,
    required this.cameraOff,
    required this.enabled,
    required this.onToggleMic,
    required this.onToggleCamera,
    required this.onSwitchCamera,
    required this.onEnd,
  });

  /// `false` until the engine is wired — the row still renders so it
  /// doesn't pop in mid-call, but mic/cam/switch taps are no-ops.
  /// "End" is always enabled (it goes through CallScreen, not the engine).
  final bool enabled;
  final bool micMuted;
  final bool cameraOff;
  final VoidCallback onToggleMic;
  final VoidCallback onToggleCamera;
  final VoidCallback onSwitchCamera;
  final VoidCallback onEnd;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _CircleButton(
            icon: micMuted ? Icons.mic_off_rounded : Icons.mic_rounded,
            active: micMuted,
            onTap: enabled ? onToggleMic : null,
            label: micMuted ? 'Activer micro' : 'Couper micro',
          ),
          _CircleButton(
            icon: cameraOff
                ? Icons.videocam_off_rounded
                : Icons.videocam_rounded,
            active: cameraOff,
            onTap: enabled ? onToggleCamera : null,
            label: cameraOff ? 'Activer caméra' : 'Couper caméra',
          ),
          _CircleButton(
            icon: Icons.cameraswitch_rounded,
            onTap: enabled ? onSwitchCamera : null,
            label: 'Changer caméra',
          ),
          // End-call: smaller pink/red filled circle, premium accent.
          _CircleButton(
            icon: Icons.call_end_rounded,
            accent: true,
            onTap: onEnd,
            label: 'Terminer le date',
          ),
        ],
      ),
    );
  }
}

class _CircleButton extends StatelessWidget {
  const _CircleButton({
    required this.icon,
    required this.onTap,
    required this.label,
    this.active = false,
    this.accent = false,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final String label;

  /// Toggle pressed state (mic muted, cam off…) — slight pink wash.
  final bool active;

  /// Highlight as the primary destructive action (end call) — full pink.
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;
    final bg = accent
        ? AppColors.brandPink
        : active
            ? AppColors.brandPink.withValues(alpha: 0.85)
            : Colors.black.withValues(alpha: 0.55);
    final border = accent
        ? AppColors.brandPink
        : Colors.white.withValues(alpha: active ? 0.0 : 0.2);
    final iconColor =
        disabled ? Colors.white.withValues(alpha: 0.45) : Colors.white;
    return Semantics(
      label: label,
      button: true,
      enabled: !disabled,
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          // Big invisible hit area so iPhone fat-finger taps land easily.
          child: Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: bg,
              border: Border.all(color: border, width: 1),
              boxShadow: accent
                  ? [
                      BoxShadow(
                        color: AppColors.brandPink.withValues(alpha: 0.45),
                        blurRadius: 16,
                        spreadRadius: 1,
                        offset: const Offset(0, 4),
                      ),
                    ]
                  : null,
            ),
            alignment: Alignment.center,
            child: Icon(icon, color: iconColor, size: 22),
          ),
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

