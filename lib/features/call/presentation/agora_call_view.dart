import 'dart:async';
import 'dart:ui';

import 'package:agora_rtc_engine/agora_rtc_engine.dart' as rtc;
import 'package:agora_uikit/agora_uikit.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../core/debug/debug_observer.dart';
import '../../../core/utils/logger.dart';
import '../data/agora_token_repository.dart';

/// In-app Agora video room built on top of `agora_uikit`.
///
/// The UIKit package owns the engine lifecycle, the event wiring, and
/// renders both the local self-view and every remote participant via
/// [AgoraVideoViewer]. We layer the DateNow chrome (header, timer,
/// Terminer button) on top in [CallScreen].
///
/// Camera + mic permissions are requested explicitly before calling
/// `AgoraClient.initialize()` — without that grant the engine silently
/// joins without media and the peer sees nothing.
///
/// The pipeline is also where future blur / progressive reveal / AI
/// filters will hook in, by intercepting the engine's video frames
/// through `agora_rtc_engine` (exposed via `client.engine`).
/// Handle returned through [AgoraCallView.onControllerCreated] so the
/// parent (CallScreen) can:
///   * hard-stop the engine BEFORE navigating to the post-call screen
///     (without this the peer's audio leaks onto the reveal UI), AND
///   * drive the call's controls (mute mic, toggle camera, switch
///     camera, end) from a custom branded button row instead of
///     `agora_uikit`'s default `AgoraVideoButtons` chrome — which used
///     to sit *under* our footer and got covered.
///
/// Implements [ChangeNotifier] so the UI can rebuild its mic/cam icons
/// without going through Riverpod.
class AgoraCallController extends ChangeNotifier {
  AgoraCallController._internal();

  static const _log = AppLogger('AgoraCtrl');

  AgoraClient? _client;
  bool _micMuted = false;
  bool _cameraOff = false;
  bool _engineStopped = false;

  /// True once the engine has been wired in. The button row hides
  /// itself until then so taps before init are no-ops.
  bool get isReady => _client != null;
  bool get micMuted => _micMuted;
  bool get cameraOff => _cameraOff;

  /// Wired by [_AgoraCallViewState] once `AgoraClient.initialize()`
  /// returns. Anything before this is silently ignored.
  void _attach(AgoraClient client) {
    if (_client != null) return;
    _client = client;
    notifyListeners();
  }

  Future<void> setMicMuted(bool muted) async {
    final c = _client;
    if (c == null || _micMuted == muted) return;
    try {
      await c.engine.muteLocalAudioStream(muted);
    } catch (e) {
      _log.warn('muteLocalAudioStream($muted) threw: $e');
      return;
    }
    _micMuted = muted;
    notifyListeners();
  }

  Future<void> toggleMic() => setMicMuted(!_micMuted);

  Future<void> setCameraOff(bool off) async {
    final c = _client;
    if (c == null || _cameraOff == off) return;
    try {
      // enableLocalVideo also stops capture (saves battery + cuts the
      // peer's view of you immediately), unlike muteLocalVideoStream
      // which just stops sending but keeps the camera running.
      await c.engine.enableLocalVideo(!off);
    } catch (e) {
      _log.warn('enableLocalVideo(${!off}) threw: $e');
      return;
    }
    _cameraOff = off;
    notifyListeners();
  }

  Future<void> toggleCamera() => setCameraOff(!_cameraOff);

  Future<void> switchCamera() async {
    final c = _client;
    if (c == null) return;
    try {
      await c.engine.switchCamera();
    } catch (e) {
      _log.warn('switchCamera threw: $e');
    }
  }

  /// Hard-stops audio + video, leaves the channel, releases the engine.
  /// Idempotent — safe to call from both [CallScreen._endCall] and the
  /// [_AgoraCallViewState.dispose] fallback.
  Future<void> stopEngine() async {
    if (_engineStopped) return;
    _engineStopped = true;
    final c = _client;
    if (c == null) return;
    _log.info('stopEngine — muting + leaving + releasing');
    final engine = c.engine;
    try {
      await engine.muteAllRemoteAudioStreams(true);
    } catch (e) {
      _log.warn('muteAllRemoteAudioStreams threw: $e');
    }
    try {
      await engine.muteLocalAudioStream(true);
    } catch (e) {
      _log.warn('muteLocalAudioStream threw: $e');
    }
    try {
      await engine.muteLocalVideoStream(true);
    } catch (e) {
      _log.warn('muteLocalVideoStream threw: $e');
    }
    try {
      await engine.stopPreview();
    } catch (e) {
      _log.warn('stopPreview threw: $e');
    }
    try {
      await engine.leaveChannel();
    } catch (e) {
      _log.warn('leaveChannel threw: $e');
    }
    try {
      c.release();
    } catch (e) {
      _log.warn('release() threw: $e');
    }
  }
}

class AgoraCallView extends ConsumerStatefulWidget {
  const AgoraCallView({
    super.key,
    required this.callId,
    required this.channelName,
    required this.onLeave,
    this.onControllerCreated,
  });

  /// The `calls` row id — used to request a token scoped to this call.
  final String callId;
  final String channelName;

  /// Called when the user taps the disconnect button so the parent can
  /// run end-of-call cleanup (Supabase status flip, navigation).
  final VoidCallback onLeave;

  /// Fires once with the controller as soon as the state mounts. The
  /// parent stores the reference and calls [AgoraCallController.stopEngine]
  /// before route changes so the engine has actually stopped capturing
  /// + playing by the time the next screen builds.
  final void Function(AgoraCallController controller)? onControllerCreated;

  @override
  ConsumerState<AgoraCallView> createState() => _AgoraCallViewState();
}

class _AgoraCallViewState extends ConsumerState<AgoraCallView> {
  static const _log = AppLogger('AGORA');

  /// Owns the public-facing controls (mic/cam/switch/stop). Created in
  /// initState so the parent can immediately receive it, wired to the
  /// engine once `AgoraClient.initialize()` returns.
  final AgoraCallController _controller = AgoraCallController._internal();

  /// How long the peer can be absent (no remote stream) mid-call before
  /// we end gracefully. Generous enough to ride out a real reconnection,
  /// short enough that a user is never left staring at an empty call.
  static const _peerAbsentGrace = Duration(seconds: 45);

  AgoraClient? _client;
  String? _error;

  // Live state for the status banner. UIKit doesn't surface these to the
  // outside so we track them here from the underlying engine events.
  bool _joined = false;
  int _remoteCount = 0;
  bool _reconnecting = false;

  /// True once at least one remote has ever joined — distinguishes
  /// "still waiting for the date" from "the date dropped".
  bool _hadRemote = false;
  int _reconnectAttempts = 0;
  bool _wasReconnecting = false;
  bool _shownAudioActive = false;
  bool _shownVideoActive = false;

  /// A short-lived status line (e.g. "Votre date a rejoint l'appel").
  String? _transientMessage;
  Timer? _transientTimer;

  /// Fires if the peer stays absent past [_peerAbsentGrace].
  Timer? _peerAbsentTimer;

  @override
  void initState() {
    super.initState();
    // Hand the parent (CallScreen) the controller now — it can wire its
    // button row immediately and the controller will fire notifyListeners
    // once the engine is actually attached.
    widget.onControllerCreated?.call(_controller);
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    if (kIsWeb) {
      _log.warn('Agora UIKit has no first-class web support');
      if (mounted) setState(() => _error = 'web_unsupported');
      return;
    }

    _log.info('Initialising — channel=${widget.channelName}');

    final cam = await Permission.camera.request();
    final mic = await Permission.microphone.request();
    _log.info(
      'Permissions — camera=${cam.name} microphone=${mic.name}',
    );
    if (!cam.isGranted || !mic.isGranted) {
      if (mounted) setState(() => _error = 'permission_denied');
      return;
    }

    // Secure join: fetch a short-lived server-signed token bound to this
    // call's channel + a stable per-user uid. The App Certificate never
    // touches the client.
    final tokenRepo = ref.read(agoraTokenRepositoryProvider);
    if (tokenRepo == null) {
      _log.error('Token repository unavailable (Supabase off)', null, null);
      if (mounted) setState(() => _error = 'token_unavailable');
      return;
    }
    final selfId = Supabase.instance.client.auth.currentUser?.id;
    if (selfId == null) {
      if (mounted) setState(() => _error = 'unauthenticated');
      return;
    }
    final uid = AgoraTokenRepository.uidForUser(selfId);

    AgoraToken token;
    try {
      token = await tokenRepo.fetchToken(
        callId: widget.callId,
        channelName: widget.channelName,
        uid: uid,
      );
    } catch (e, st) {
      _log.error('Token fetch failed: $e', e, st);
      if (mounted) setState(() => _error = 'token_failed');
      return;
    }
    // Publish non-sensitive token diagnostics for the Debug screen.
    ref.read(agoraTokenDebugProvider.notifier).state = AgoraTokenDebugInfo(
      generated: true,
      uid: token.uid,
      expiresAt: token.expiresAt,
    );

    final client = AgoraClient(
      agoraConnectionData: AgoraConnectionData(
        appId: token.appId,
        channelName: token.channelName,
        tempToken: token.token,
        uid: token.uid,
      ),
      enabledPermission: const [
        Permission.camera,
        Permission.microphone,
      ],
    );

    try {
      await client.initialize();
      _log.info(
        'Engine initialised — joined channel=${widget.channelName} '
        '(token-secured)',
      );
      // Wire a secondary event handler on the underlying engine so we
      // get the granular signals UIKit doesn't surface (remote user
      // join/leave with reason, connection state changes, error codes,
      // first remote frame). Crucial when debugging "I don't see the
      // other person" — every Agora-side decision is now in the log.
      client.engine.registerEventHandler(
        rtc.RtcEngineEventHandler(
          onJoinChannelSuccess: (connection, elapsed) {
            _log.info(
              'onJoinChannelSuccess — channel=${connection.channelId} '
              'uid=${connection.localUid} elapsed=${elapsed}ms',
            );
            if (!mounted) return;
            setState(() => _joined = true);
            DebugLog.agora('joined channel'); // debug-observer
            _publishDebug();
          },
          onUserJoined: (connection, remoteUid, elapsed) {
            // Capture more diagnostic context than just the uid — UIKit's
            // user list size + mainAgoraUser uid let a post-mortem
            // confirm the OneToOneLayout actually sees the peer. If
            // remoteCount goes from 0 → 1 but the screen still shows
            // local fullscreen, the layout is broken; here we'd see
            // remote_user_added but mainAgoraUser still on the local uid.
            final sc = client.sessionController.value;
            _log.info(
              'onUserJoined — remoteUid=$remoteUid elapsed=${elapsed}ms '
              'channel=${connection.channelId} '
              'sessionController.users.len=${sc.users.length} '
              'mainAgoraUser.uid=${sc.mainAgoraUser.uid} '
              'localUid=${sc.localUid}',
            );
            if (!mounted) return;
            _peerAbsentTimer?.cancel();
            setState(() {
              _remoteCount++;
              _hadRemote = true;
            });
            DebugLog.agora('peer joined'); // debug-observer
            _flashMessage('Votre date a rejoint l\'appel');
            _publishDebug();
          },
          onUserOffline: (connection, remoteUid, reason) {
            _log.info(
              'onUserOffline — remoteUid=$remoteUid reason=$reason',
            );
            if (!mounted) return;
            DebugLog.agora('peer left'); // debug-observer
            setState(() =>
                _remoteCount = (_remoteCount - 1).clamp(0, 99));
            // Peer gone: give them a grace window to reconnect before
            // ending the call so a brief drop doesn't kill the date.
            if (_remoteCount == 0 && _hadRemote) {
              _flashMessage('Votre date s\'est déconnecté…');
              _peerAbsentTimer?.cancel();
              _peerAbsentTimer = Timer(_peerAbsentGrace, () {
                if (mounted && _remoteCount == 0) {
                  _log.info('Peer absent past grace — ending call');
                  widget.onLeave();
                }
              });
            }
            _publishDebug();
          },
          onFirstRemoteVideoFrame:
              (connection, remoteUid, width, height, elapsed) {
            _log.info(
              'onFirstRemoteVideoFrame — remoteUid=$remoteUid '
              'size=${width}x$height elapsed=${elapsed}ms',
            );
          },
          onRemoteAudioStateChanged:
              (connection, remoteUid, state, reason, elapsed) {
            // Log EVERY state transition (was: only flash on decoding).
            // The state + reason pair is enough to tell remote-not-published
            // (state=stopped reason=remoteMuted) from remote-muted-by-us
            // (state=stopped reason=localMuted) from network-stall
            // (state=frozen reason=networkCongestion).
            _log.info(
              'onRemoteAudioStateChanged — remoteUid=$remoteUid '
              'state=$state reason=$reason elapsed=${elapsed}ms',
            );
            if (state == rtc.RemoteAudioState.remoteAudioStateDecoding &&
                !_shownAudioActive) {
              _shownAudioActive = true;
              _flashMessage('Micro activé');
            }
          },
          onRemoteVideoStateChanged:
              (connection, remoteUid, state, reason, elapsed) {
            // Same exhaustive logging as audio — the video pipeline
            // states are the most diagnostic signal for a "remote feed
            // invisible" report : if we never see
            // `remoteVideoStateDecoding`, the stream never arrived; if
            // we see it but the screen stays empty, the layout / canvas
            // is the culprit.
            _log.info(
              'onRemoteVideoStateChanged — remoteUid=$remoteUid '
              'state=$state reason=$reason elapsed=${elapsed}ms',
            );
            if (state == rtc.RemoteVideoState.remoteVideoStateDecoding &&
                !_shownVideoActive) {
              _shownVideoActive = true;
              _flashMessage('Caméra active');
            }
          },
          // Local capture state — proves enableVideo() / startPreview()
          // ran successfully. Pairs with the local PIP rendering : a
          // user complaining "I don't see my own camera" can be told
          // immediately whether the local pipeline is healthy.
          onLocalVideoStateChanged: (source, state, reason) {
            _log.info(
              'onLocalVideoStateChanged — source=$source '
              'state=$state reason=$reason',
            );
          },
          // Local audio capture — same idea for the mic side.
          onLocalAudioStateChanged: (connection, state, reason) {
            _log.info(
              'onLocalAudioStateChanged — state=$state reason=$reason',
            );
          },
          onConnectionStateChanged: (connection, state, reason) {
            _log.info(
              'onConnectionStateChanged — state=$state reason=$reason',
            );
            if (!mounted) return;
            final reconnecting = state ==
                    rtc.ConnectionStateType.connectionStateReconnecting ||
                reason ==
                    rtc.ConnectionChangedReasonType
                        .connectionChangedInterrupted;
            // Count each fresh drop into a reconnecting state.
            if (reconnecting && !_wasReconnecting) {
              _reconnectAttempts++;
              _log.warn('Reconnecting — attempt #$_reconnectAttempts');
              DebugLog.agora('reconnect attempt #$_reconnectAttempts'); // debug-observer
            }
            _wasReconnecting = reconnecting;
            setState(() => _reconnecting = reconnecting);
            _publishDebug();
          },
          onTokenPrivilegeWillExpire: (connection, token) {
            _log.warn('onTokenPrivilegeWillExpire — channel=${connection.channelId}');
          },
          onError: (err, msg) {
            _log.warn('onError — code=$err msg=$msg');
          },
          // debug-observer — feed the test overlay's network indicator.
          onNetworkQuality:
              (connection, remoteUid, txQuality, rxQuality) {
            if (!mounted) return;
            DebugObserver.instance.setNetQuality(_qualityLabel(rxQuality));
          },
        ),
      );
      if (!mounted) return;
      setState(() => _client = client);
      // Wire the controller to the live engine — its `isReady` flips to
      // true and the parent's button row stops being a no-op.
      _controller._attach(client);
      _publishDebug();
    } catch (e, st) {
      _log.error('Engine init failed: $e', e, st);
      if (mounted) setState(() => _error = e.toString());
    }
  }

  /// Maps an Agora [rtc.QualityType] to a short human label for the
  /// test-observation overlay. Debug-only — never affects the call.
  static String _qualityLabel(rtc.QualityType q) => switch (q) {
        rtc.QualityType.qualityExcellent => 'excellent',
        rtc.QualityType.qualityGood => 'bon',
        rtc.QualityType.qualityPoor => 'moyen',
        rtc.QualityType.qualityBad ||
        rtc.QualityType.qualityVbad =>
          'faible',
        rtc.QualityType.qualityDown => 'coupé',
        _ => '—',
      };

  /// Shows [msg] as a status line for ~2.8 s, then clears it.
  void _flashMessage(String msg) {
    if (!mounted) return;
    _transientTimer?.cancel();
    setState(() => _transientMessage = msg);
    _transientTimer = Timer(const Duration(milliseconds: 2800), () {
      if (mounted) setState(() => _transientMessage = null);
    });
  }

  /// Mirrors live connection state into the Debug provider.
  void _publishDebug() {
    ref.read(agoraConnectionDebugProvider.notifier).state =
        AgoraConnectionDebug(
      joined: _joined,
      remoteCount: _remoteCount,
      reconnecting: _reconnecting,
      reconnectAttempts: _reconnectAttempts,
    );
  }

  @override
  void dispose() {
    _transientTimer?.cancel();
    _peerAbsentTimer?.cancel();
    ref.read(agoraConnectionDebugProvider.notifier).state =
        AgoraConnectionDebug.none;
    // Belt-and-suspenders: if the parent navigated without calling
    // stopEngine() (older code paths, errors, …), still tear the engine
    // down here. Fire-and-forget because dispose() must return
    // synchronously — stopEngine itself is idempotent.
    unawaited(_controller.stopEngine());
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return _ErrorPanel(error: _error!);
    }
    final c = _client;
    if (c == null) {
      return const _LoadingPanel();
    }
    final banner = _resolveBanner();

    return Stack(
      children: [
        // 1:1 video layout — the dating room has exactly two
        // participants (caller + callee). `Layout.oneToOne` puts the
        // REMOTE peer in fullscreen and the LOCAL self in a small
        // rounded top-right PIP (~20%h × 33%w, see
        // `agora_uikit/.../one_to_one_layout.dart:78-152`), which is the
        // correct semantics for a date.
        //
        // Was `Layout.floating` — that variant always promoted the
        // FIRST joiner (us) to fullscreen and pushed every subsequent
        // user into a 20%-of-screen-height scrollable PIP strip
        // anchored at the TOP of the screen. Combined with this
        // file's `BackdropFilter` (sigma-15 blur over the whole
        // viewer) and the parent CallScreen's top chrome (timer pill
        // + EN DIRECT pill sitting in the same vertical band), the
        // remote PIP became completely indistinguishable from a
        // blurred glyph at the very top — the symptom users reported
        // was "I only see my own (blurred) camera, no peer".
        AgoraVideoViewer(
          client: c,
          layoutType: Layout.oneToOne,
          showAVState: false,
          showNumberOfUsers: false,
          enableHostControls: false,
        ),

        // Mystery blur — the heart of the DateNow product. A sigma-15
        // BackdropFilter sits over the entire video for the whole call.
        // There is intentionally NO in-call toggle: the blur lifts only
        // at the post-call reveal. Placed below the controls so the
        // mute / camera / end buttons stay sharp and tappable.
        Positioned.fill(
          child: ClipRect(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
              child: const SizedBox.expand(),
            ),
          ),
        ),

        // NOTE: `agora_uikit`'s `AgoraVideoButtons` are intentionally
        // NOT mounted here. They render a large default chrome at the
        // bottom-center that fights with CallScreen's own footer and
        // hides tappable areas on iPhone. CallScreen draws its own
        // compact button row driven by [AgoraCallController].

        // Permanent caption so the blur reads as a deliberate feature,
        // not a broken stream.
        const Positioned(
          bottom: 130,
          left: 0,
          right: 0,
          child: Center(child: _BlurCaption()),
        ),

        if (banner != null)
          Positioned(
            top: 100,
            left: 0,
            right: 0,
            child: Center(
              child: _StatusBanner(text: banner),
            ),
          ),
      ],
    );
  }

  /// Returns the banner text to show, or null when the call is in its
  /// happy path (joined + at least one remote + stable connection).
  ///
  /// A transient message (peer joined, mic/cam on) wins over the steady
  /// lifecycle banners so the most recent event is always visible.
  String? _resolveBanner() {
    if (_transientMessage != null) return _transientMessage;
    if (_reconnecting) return 'Reconnexion en cours…';
    if (!_joined) return 'Connexion au date vidéo…';
    if (_remoteCount == 0) {
      return _hadRemote
          ? 'Votre date se reconnecte…'
          : 'En attente de votre date…';
    }
    return null;
  }
}

class _BlurCaption extends StatelessWidget {
  const _BlurCaption();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: 8,
        ),
        decoration: BoxDecoration(
          color: AppColors.brandPink.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: AppColors.brandPink.withValues(alpha: 0.4),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.blur_on_rounded,
                color: AppColors.brandPink, size: 16),
            const SizedBox(width: 6),
            Text(
              'Caméra floutée jusqu\'à la fin du date',
              style: AppTypography.caption.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: 8,
        ),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
        ),
        child: Text(
          text,
          style: AppTypography.caption.copyWith(
            color: Colors.white,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _LoadingPanel extends StatelessWidget {
  const _LoadingPanel();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.background,
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            height: 32,
            width: 32,
            child: CircularProgressIndicator(
              strokeWidth: 2.5,
              valueColor: AlwaysStoppedAnimation(AppColors.brandPink),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            'Connexion vidéo…',
            style: AppTypography.caption.copyWith(
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorPanel extends StatelessWidget {
  const _ErrorPanel({required this.error});

  final String error;

  @override
  Widget build(BuildContext context) {
    // Every branch maps an internal code to a calm, non-technical line —
    // the raw error / engine code is never shown to the user (it stays
    // in the logs).
    final (icon, title, body) = switch (error) {
      'permission_denied' => (
          Icons.videocam_off_rounded,
          'Caméra et micro nécessaires',
          'Active la caméra et le micro dans les réglages pour vivre '
              'le date en vidéo.',
        ),
      'web_unsupported' => (
          Icons.devices_rounded,
          'Indisponible sur le web',
          'Le date vidéo se vit depuis l\'application mobile DateNow.',
        ),
      'token_unavailable' || 'token_failed' => (
          Icons.lock_clock_rounded,
          'Connexion sécurisée indisponible',
          'On n\'a pas pu sécuriser ce date pour l\'instant. Réessaie '
              'dans un moment.',
        ),
      'unauthenticated' => (
          Icons.person_off_rounded,
          'Session expirée',
          'Reconnecte-toi pour reprendre tes dates.',
        ),
      _ => (
          Icons.sentiment_dissatisfied_rounded,
          'Date interrompu',
          'Quelque chose a coupé la connexion vidéo. Tu peux revenir '
              'et réessayer.',
        ),
    };
    return Container(
      color: AppColors.background,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 56, color: AppColors.textTertiary),
          const SizedBox(height: AppSpacing.md),
          Text(
            title,
            textAlign: TextAlign.center,
            style: AppTypography.h3,
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            body,
            textAlign: TextAlign.center,
            style: AppTypography.body.copyWith(color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }
}
