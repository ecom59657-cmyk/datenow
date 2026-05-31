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

  /// Hard cap on how long a "Votre date semble déconnecté" countdown
  /// can run before the call is force-ended. Was 45 s — testers
  /// reported the UX felt like an eternity, and the previous banner
  /// chained "déconnecté → se reconnecte" without any actual
  /// reconnection event. New rule: a strict, visible 10 s countdown
  /// is the only signal a peer offline can produce.
  static const _remoteOfflineGrace = Duration(seconds: 10);

  /// Hard cap on how long OUR OWN Agora connection can stay in the
  /// `reconnecting` state before we end the call. Was 30 s. The
  /// engine itself only counts a few short attempts before giving up,
  /// so 15 s is a comfortable upper bound while keeping the UI from
  /// freezing on "Reconnexion en cours…" for half a minute.
  static const _reconnectAbortGrace = Duration(seconds: 15);

  AgoraClient? _client;
  String? _error;

  // ── Strict call-phase state machine ────────────────────────────
  //
  // The banner shown to the user is a pure function of these fields
  // (see [_resolveBanner]). Each field is set by ONE Agora event —
  // no derived flag lies about a state Agora did not actually
  // announce.
  //
  //  _joined            true after the first onJoinChannelSuccess.
  //                     Never flips back to false; the "Connexion au
  //                     date vidéo…" banner only shows during the
  //                     initial join (cf. _resolveBanner).
  //  _hadRemote         latching — true once any peer joins. Drives
  //                     the "En attente de votre date…" vs "no banner"
  //                     decision.
  //  _remoteUid         currently-rendered peer uid, or null when
  //                     no peer is on the call.
  //  _selfReconnecting  true ONLY when Agora explicitly emits
  //                     `connectionStateReconnecting` for OUR client.
  //                     Was previously named `_reconnecting`; the new
  //                     name removes the ambiguity with peer-offline.
  //  _remoteOfflineSecondsLeft  countdown value (10 → 0) shown when
  //                     the remote went offline. Driven by the
  //                     1-second ticker [_remoteOfflineCountdownTimer].
  bool _joined = false;
  int _remoteCount = 0;
  bool _selfReconnecting = false;

  /// Tracked separately from [_remoteCount] because we render the
  /// REMOTE [AgoraVideoView] ourselves (hand-rolled fullscreen +
  /// top-right PIP) instead of going through `AgoraVideoViewer` /
  /// `OneToOneLayout`. The UIKit layouts hard-code their own PIP
  /// position which collided with this app's HUD chrome — see
  /// build() for the rationale.
  int? _remoteUid;

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

  /// 1-second ticker for the remote-offline countdown. Armed on
  /// onUserOffline (when count drops to 0 and a remote had been
  /// present), cancelled on onUserJoined of the same uid, decrements
  /// [_remoteOfflineSecondsLeft] each tick, and fires
  /// `widget.onLeave()` when the counter hits 0.
  Timer? _remoteOfflineCountdownTimer;

  /// Drives the banner text "Votre date semble déconnecté. Fin dans
  /// Ns…" — null when there is no countdown in progress.
  int? _remoteOfflineSecondsLeft;

  /// Fires if we stay in the `reconnecting` connection state past
  /// [_reconnectAbortGrace] — i.e. the local network is gone for good.
  /// On expiry we call `widget.onLeave()` so CallScreen ends the call
  /// cleanly (Supabase status, presence reset, post-call navigation)
  /// instead of leaving the user staring at "Reconnexion en cours…".
  Timer? _reconnectAbortTimer;

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
            // Differentiate "first peer ever" from "peer back after
            // an offline countdown" so the flash message is honest —
            // the brief explicitly asked for "Votre date revient…"
            // on the rejoin path.
            final isRejoin = _hadRemote && _remoteUid == null;
            setState(() {
              _remoteCount++;
              _hadRemote = true;
              // Promote this uid to the fullscreen feed. 1:1 by
              // construction so we never need to pick between several
              // remotes — the most recent join is the one we render.
              _remoteUid = remoteUid;
            });
            // Cancel any pending offline countdown — the peer is back.
            _cancelRemoteOfflineCountdown();
            DebugLog.agora(isRejoin ? 'peer back' : 'peer joined'); // debug-observer
            _flashMessage(
              isRejoin
                  ? 'Votre date revient…'
                  : 'Votre date a rejoint l\'appel',
            );
            _publishDebug();
          },
          onUserOffline: (connection, remoteUid, reason) {
            _log.info(
              'onUserOffline — remoteUid=$remoteUid reason=$reason',
            );
            if (!mounted) return;
            DebugLog.agora('peer left'); // debug-observer
            setState(() {
              _remoteCount = (_remoteCount - 1).clamp(0, 99);
              if (remoteUid == _remoteUid) _remoteUid = null;
            });
            // Peer gone — start a strict, visible countdown. If they
            // come back (onUserJoined) before it hits 0 it gets
            // cancelled and the call continues. Otherwise we end
            // cleanly via widget.onLeave().
            if (_remoteCount == 0 && _hadRemote) {
              _startRemoteOfflineCountdown();
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
            // ONLY count a true Agora-emitted reconnecting/interrupted
            // event. The banner "Reconnexion en cours…" must never
            // fire on a derived guess — that was the build 32 bug
            // where peer-offline + own-connection-OK still showed
            // "se reconnecte".
            final reconnecting = state ==
                    rtc.ConnectionStateType.connectionStateReconnecting ||
                reason ==
                    rtc.ConnectionChangedReasonType
                        .connectionChangedInterrupted;
            if (reconnecting && !_wasReconnecting) {
              _reconnectAttempts++;
              _log.warn(
                'Self reconnecting — attempt #$_reconnectAttempts '
                '(grace ${_reconnectAbortGrace.inSeconds}s)',
              );
              DebugLog.agora('reconnect attempt #$_reconnectAttempts'); // debug-observer
              _reconnectAbortTimer?.cancel();
              _reconnectAbortTimer = Timer(_reconnectAbortGrace, () {
                if (!mounted || !_selfReconnecting) return;
                _log.warn(
                  'Self reconnect grace expired '
                  '(${_reconnectAbortGrace.inSeconds}s) — ending call',
                );
                DebugLog.agora('reconnect grace expired'); // debug-observer
                widget.onLeave();
              });
            }
            if (!reconnecting && _wasReconnecting) {
              _log.info(
                'Self reconnect successful — cancelling abort grace',
              );
              _reconnectAbortTimer?.cancel();
              _reconnectAbortTimer = null;
            }
            _wasReconnecting = reconnecting;
            setState(() => _selfReconnecting = reconnecting);
            _publishDebug();
          },
          onTokenPrivilegeWillExpire: (connection, token) {
            // Token TTL is 15 min server-side (see
            // supabase/functions/generate-agora-token/index.ts:28).
            // Call cap is `AppConfig.maxCallDuration` (5 min today).
            // The 3× safety margin means a fresh token always outlives
            // the longest possible call — we log + carry on. If the
            // call cap is ever raised above ~12 min, this handler must
            // be upgraded to fetch a fresh token via
            // `agoraTokenRepositoryProvider.fetchToken` and feed it to
            // `engine.renewToken(...)` before the privilege expires.
            _log.warn(
              'onTokenPrivilegeWillExpire — channel=${connection.channelId} '
              '(no auto-renew; current call cap << 15 min token TTL)',
            );
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
      reconnecting: _selfReconnecting,
      reconnectAttempts: _reconnectAttempts,
    );
  }

  /// Starts the 10-second visible countdown that the banner reads from.
  /// Cancellable (via [_cancelRemoteOfflineCountdown]) up to the very
  /// last tick — peer rejoining clears the countdown without ending
  /// the call.
  void _startRemoteOfflineCountdown() {
    _remoteOfflineCountdownTimer?.cancel();
    _log.info(
      'remote-offline countdown START — '
      '${_remoteOfflineGrace.inSeconds}s before auto-end',
    );
    DebugLog.agora('remote offline countdown 10s'); // debug-observer
    setState(() {
      _remoteOfflineSecondsLeft = _remoteOfflineGrace.inSeconds;
    });
    _remoteOfflineCountdownTimer = Timer.periodic(
      const Duration(seconds: 1),
      (timer) {
        if (!mounted) {
          timer.cancel();
          return;
        }
        final remaining = (_remoteOfflineSecondsLeft ?? 0) - 1;
        if (remaining <= 0) {
          timer.cancel();
          _remoteOfflineCountdownTimer = null;
          setState(() => _remoteOfflineSecondsLeft = 0);
          _log.info(
            'remote-offline countdown 0 — ending call (trigger=remote_timeout)',
          );
          DebugLog.agora('remote offline countdown 0 → ending'); // debug-observer
          widget.onLeave();
          return;
        }
        setState(() => _remoteOfflineSecondsLeft = remaining);
      },
    );
  }

  /// Stops the countdown without ending the call — used when the peer
  /// rejoins (onUserJoined) before the timer hits 0.
  void _cancelRemoteOfflineCountdown() {
    if (_remoteOfflineCountdownTimer == null) return;
    _log.info('remote-offline countdown CANCEL — peer back');
    DebugLog.agora('remote offline countdown cancelled'); // debug-observer
    _remoteOfflineCountdownTimer?.cancel();
    _remoteOfflineCountdownTimer = null;
    setState(() => _remoteOfflineSecondsLeft = null);
  }

  @override
  void dispose() {
    _transientTimer?.cancel();
    _remoteOfflineCountdownTimer?.cancel();
    _reconnectAbortTimer?.cancel();
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

    // Premium FaceTime-style layer order (bottom → top):
    //
    //   0. Fullscreen video — REMOTE if a peer is online, otherwise
    //      LOCAL self as the waiting placeholder. Hand-rolled with
    //      AgoraVideoView + VideoViewController so the PIP geometry
    //      below is ours, not agora_uikit's hard-coded
    //      `Alignment.topRight + EdgeInsets.only(top: 8)` that
    //      collided with CallScreen's top HUD.
    //   1. Mystery blur — sigma-15 BackdropFilter over the fullscreen
    //      video, never the PIP. The product concept (peer blurred
    //      until post-call reveal) is preserved. The LOCAL PIP sits
    //      ABOVE this layer so the user sees themselves sharply — the
    //      FaceTime / Tinder Live UX (hair check, framing) without
    //      compromising the reveal moment.
    //   2. Local PIP — top-right, safe-area aware (top = padding +
    //      ~60 dp = clears CallScreen's HUD pills with breathing
    //      room), rounded corners + soft shadow, switch-camera icon
    //      tucked into its own bottom-right. Only mounted once a
    //      remote is present (otherwise local is already fullscreen).
    //   3. Status banner — transient top-center pill (e.g. "Caméra
    //      active"). Wins on top so the most recent event is the
    //      most visible.
    //   4. Blur caption — the permanent "Caméra floutée jusqu'à la
    //      fin du date" tag near the bottom. Mounted last so it
    //      never gets eaten by the blur on the layer below.
    final remoteUid = _remoteUid;
    return Stack(
      children: [
        // 0. Fullscreen video.
        Positioned.fill(child: _buildFullscreenVideo(c, remoteUid)),

        // 1. Mystery blur — covers ONLY the fullscreen video layer.
        Positioned.fill(
          child: ClipRect(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
              child: const SizedBox.expand(),
            ),
          ),
        ),

        // 2. Local PIP (only when a remote is on the call — otherwise
        //    the local is already fullscreen as the waiting view).
        if (remoteUid != null)
          _LocalPip(
            engine: c.sessionController.value.engine!,
            onSwitchCamera: () => _controller.switchCamera(),
          ),

        // 3. Permanent caption that frames the blur as deliberate UX.
        const Positioned(
          bottom: 130,
          left: 0,
          right: 0,
          child: Center(child: _BlurCaption()),
        ),

        // 4. Transient status banner (peer joined, mic active, …).
        if (banner != null)
          Positioned(
            top: MediaQuery.of(context).padding.top + 70,
            left: 0,
            right: 0,
            child: Center(child: _StatusBanner(text: banner)),
          ),

        // NOTE: agora_uikit's `AgoraVideoButtons` are intentionally NOT
        // mounted here. CallScreen draws its own compact button row
        // driven by [AgoraCallController] so the chrome stays inside a
        // single Stack and the tap targets don't fight.
      ],
    );
  }

  /// The bottom-most video layer. Renders the REMOTE peer fullscreen
  /// when one is online, otherwise the LOCAL self so the user is not
  /// staring at a black hole while the peer connects. Both branches
  /// use the underlying `agora_rtc_engine` 6.x VideoViewController API
  /// directly — see the build() rationale for why we sidestepped
  /// `AgoraVideoViewer` / `OneToOneLayout`.
  Widget _buildFullscreenVideo(AgoraClient client, int? remoteUid) {
    final engine = client.sessionController.value.engine;
    if (engine == null) {
      return Container(color: AppColors.background);
    }
    if (remoteUid != null) {
      return rtc.AgoraVideoView(
        controller: rtc.VideoViewController.remote(
          rtcEngine: engine,
          // `renderModeHidden` = cover (crop excess) — the standard
          // for fullscreen video so we never get black letterbox bars.
          canvas: rtc.VideoCanvas(
            uid: remoteUid,
            renderMode: rtc.RenderModeType.renderModeHidden,
          ),
          connection: rtc.RtcConnection(channelId: widget.channelName),
        ),
      );
    }
    return rtc.AgoraVideoView(
      controller: rtc.VideoViewController(
        rtcEngine: engine,
        canvas: const rtc.VideoCanvas(
          uid: 0,
          renderMode: rtc.RenderModeType.renderModeHidden,
        ),
      ),
    );
  }

  /// Returns the banner text to show, or null when the call is in its
  /// happy path (joined + at least one remote + stable connection).
  ///
  /// A transient message (peer joined, mic/cam on) wins over the steady
  /// lifecycle banners so the most recent event is always visible.
  String? _resolveBanner() {
    // Strict precedence — derived from explicit Agora events only.
    // No banner is ever shown for a state Agora did not announce.
    //
    // 1. Short-lived flash (peer joined / mic active / cam active)
    //    wins so the most recent event is always visible.
    if (_transientMessage != null) return _transientMessage;
    // 2. OUR OWN connection is reconnecting — Agora has explicitly
    //    emitted `connectionStateReconnecting`. Distinct from
    //    "peer offline".
    if (_selfReconnecting) return 'Reconnexion en cours…';
    // 3. Peer went offline and the 10 s countdown is in progress.
    //    The banner counts down each second so the user knows
    //    exactly when the call will end. No misleading "se reconnecte"
    //    message — peer offline is peer offline.
    final offlineLeft = _remoteOfflineSecondsLeft;
    if (offlineLeft != null) {
      if (offlineLeft <= 0) {
        return 'Fin de l\'appel…';
      }
      return 'Votre date semble déconnecté. Fin dans ${offlineLeft}s…';
    }
    // 4. Initial join screen — ONLY while we are not yet in the
    //    channel AND no peer has ever been seen. Once `_hadRemote`
    //    latches true the call is officially "started" and this
    //    banner is forbidden (was a reported build 32 bug: the
    //    banner re-appeared after a remote drop).
    if (!_joined && !_hadRemote) return 'Connexion au date vidéo…';
    // 5. We are in the channel but the peer has not joined yet.
    if (!_hadRemote) return 'En attente de votre date…';
    // 6. Happy path — joined, peer present, no countdown. No banner.
    return null;
  }
}

/// Premium top-right PIP showing the LOCAL self camera.
///
/// Geometry rationale :
///
/// * `top = MediaQuery.padding.top + 60` — `padding.top` is the device
///   safe area (notch / Dynamic Island / status bar), and 60 dp leaves
///   the CallScreen's HUD pills (~34 dp tall + 12 dp top padding) with
///   ~14 dp of breathing room. Verified across iPhone SE (safeTop=20),
///   iPhone 15 (47), iPhone 15 Pro Max (59) — the PIP always clears
///   the HUD.
/// * `right = 16` — matches the bottom control bar's horizontal margin
///   so the right edges line up vertically on tall devices.
/// * `96 × 152` — close to FaceTime's PIP proportions (portrait 0.63
///   ratio). Slightly under the 110 dp wide / 180 dp tall upper bound
///   in the brief so it never crowds even iPhone SE width (320 dp).
/// * `BorderRadius.circular(22)` — matches iOS continuous-corner feel.
/// * Soft shadow `(blur 24, offset y=8, black α=0.35)` — lifts the PIP
///   off the blurred remote without a hard line.
///
/// Sits **above** the BackdropFilter in build()'s Stack, so the user
/// sees themselves *sharply* even though the remote is blurred — that's
/// the FaceTime / Tinder Live aesthetic and crucially preserves the
/// DateNow "reveal at post-call" concept (it's the PEER that stays
/// hidden, not the self).
///
/// The switch-camera affordance lives inside the PIP at its
/// bottom-right corner — a one-tap shortcut to flip front/rear without
/// reaching down to the bottom control bar. The same callback is also
/// wired on the bottom row, so both gestures work.
class _LocalPip extends StatelessWidget {
  const _LocalPip({
    required this.engine,
    required this.onSwitchCamera,
  });

  final rtc.RtcEngine engine;
  final VoidCallback onSwitchCamera;

  static const double _width = 96;
  static const double _height = 152;
  static const double _radius = 22;
  static const double _rightInset = 16;
  static const double _topOffsetBelowHud = 60;

  @override
  Widget build(BuildContext context) {
    final safeTop = MediaQuery.of(context).padding.top;
    return Positioned(
      top: safeTop + _topOffsetBelowHud,
      right: _rightInset,
      child: SizedBox(
        width: _width,
        height: _height,
        child: Stack(
          children: [
            // Drop shadow lives on the OUTER container; the inner
            // ClipRRect can then clip the AgoraVideoView cleanly
            // without leaking the shadow through the rounded corners.
            DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(_radius),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.35),
                    blurRadius: 24,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(_radius),
                child: SizedBox.expand(
                  child: rtc.AgoraVideoView(
                    controller: rtc.VideoViewController(
                      rtcEngine: engine,
                      canvas: const rtc.VideoCanvas(
                        uid: 0,
                        // Cover (crop excess) so the self view fills
                        // the PIP edge-to-edge without letterbox bars.
                        renderMode: rtc.RenderModeType.renderModeHidden,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // Switch-camera affordance, tucked into the PIP's
            // bottom-right corner. 28 dp pill, dark translucent with a
            // thin white border for iOS-native feel. Sits on top of
            // the ClipRRect (inside the Stack) so the tap surface is
            // a regular widget — no GestureDetector behind clipped
            // pixels.
            Positioned(
              right: 6,
              bottom: 6,
              child: Material(
                color: Colors.transparent,
                shape: const CircleBorder(),
                child: InkWell(
                  onTap: onSwitchCamera,
                  customBorder: const CircleBorder(),
                  child: Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.black.withValues(alpha: 0.55),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.25),
                      ),
                    ),
                    alignment: Alignment.center,
                    child: const Icon(
                      Icons.cameraswitch_rounded,
                      color: Colors.white,
                      size: 14,
                    ),
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
