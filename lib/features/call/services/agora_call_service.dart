import 'dart:async';

import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/logger.dart';
import '../domain/agora_token.dart';

/// Lifecycle of the local participant in an Agora channel. The screen
/// reacts to these states to show the right UI (connecting → joined →
/// the peer joined → ended/failed).
enum AgoraCallStatus { idle, connecting, joined, ended, failed }

/// Snapshot of the call session exposed to the UI. Mutable through the
/// service's stream — never poll it directly.
class AgoraCallState {
  const AgoraCallState({
    this.status = AgoraCallStatus.idle,
    this.localUid,
    this.remoteUid,
    this.micMuted = false,
    this.cameraEnabled = true,
    this.errorMessage,
  });

  final AgoraCallStatus status;
  final int? localUid;
  final int? remoteUid;
  final bool micMuted;
  final bool cameraEnabled;
  final String? errorMessage;

  AgoraCallState copyWith({
    AgoraCallStatus? status,
    int? localUid,
    int? remoteUid,
    bool? micMuted,
    bool? cameraEnabled,
    String? errorMessage,
    bool clearRemote = false,
    bool clearError = false,
  }) {
    return AgoraCallState(
      status: status ?? this.status,
      localUid: localUid ?? this.localUid,
      remoteUid: clearRemote ? null : (remoteUid ?? this.remoteUid),
      micMuted: micMuted ?? this.micMuted,
      cameraEnabled: cameraEnabled ?? this.cameraEnabled,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}

/// Wraps the [RtcEngine] singleton — created and disposed per call.
///
/// The service is the **only** code that imports `agora_rtc_engine`; the
/// rest of the app interacts with it through the [AgoraCallState] stream
/// and the imperative methods.
class AgoraCallService {
  AgoraCallService();

  static const _log = AppLogger('AgoraCall');

  RtcEngine? _engine;
  final _controller = StreamController<AgoraCallState>.broadcast();
  AgoraCallState _state = const AgoraCallState();

  Stream<AgoraCallState> get stream => _controller.stream;
  AgoraCallState get state => _state;

  /// Engine handle exposed for [AgoraVideoView] rendering. Null until
  /// [join] succeeds.
  RtcEngine? get engine => _engine;

  void _emit(AgoraCallState next) {
    _state = next;
    _controller.add(next);
  }

  /// Joins the channel described by [token]. Throws if anything fails
  /// during init; never leaves the engine half-initialised.
  Future<void> join(AgoraToken token) async {
    _log.info(
      'join channel=${token.channelName} uid=${token.uid} appId=${token.appId}',
    );
    _emit(_state.copyWith(
      status: AgoraCallStatus.connecting,
      localUid: token.uid,
      clearError: true,
    ));

    try {
      final engine = createAgoraRtcEngine();
      await engine.initialize(RtcEngineContext(appId: token.appId));
      _engine = engine;

      engine.registerEventHandler(
        RtcEngineEventHandler(
          onJoinChannelSuccess: (connection, elapsed) {
            _log.info('joined channel (uid=${connection.localUid})');
            _emit(_state.copyWith(status: AgoraCallStatus.joined));
          },
          onUserJoined: (connection, remoteUid, elapsed) {
            _log.info('peer joined: $remoteUid');
            _emit(_state.copyWith(remoteUid: remoteUid));
          },
          onUserOffline: (connection, remoteUid, reason) {
            _log.info('peer offline: $remoteUid ($reason)');
            _emit(_state.copyWith(clearRemote: true));
          },
          onError: (err, msg) {
            _log.warn('agora error: $err $msg');
          },
        ),
      );

      await engine.enableVideo();
      await engine.enableAudio();
      await engine.startPreview();

      await engine.joinChannel(
        token: token.token,
        channelId: token.channelName,
        uid: token.uid,
        options: const ChannelMediaOptions(
          clientRoleType: ClientRoleType.clientRoleBroadcaster,
          channelProfile: ChannelProfileType.channelProfileLiveBroadcasting,
          publishCameraTrack: true,
          publishMicrophoneTrack: true,
          autoSubscribeAudio: true,
          autoSubscribeVideo: true,
        ),
      );
    } catch (e, st) {
      _log.error('join failed: $e', e, st);
      await _disposeEngine();
      _emit(_state.copyWith(
        status: AgoraCallStatus.failed,
        errorMessage: e.toString(),
      ));
      rethrow;
    }
  }

  Future<void> leave() async {
    _log.info('leave channel');
    try {
      await _engine?.leaveChannel();
    } catch (e) {
      _log.warn('leaveChannel threw: $e');
    }
    await _disposeEngine();
    _emit(_state.copyWith(status: AgoraCallStatus.ended, clearRemote: true));
  }

  Future<void> setMicMuted(bool muted) async {
    if (_engine == null) return;
    await _engine!.muteLocalAudioStream(muted);
    _emit(_state.copyWith(micMuted: muted));
  }

  Future<void> setCameraEnabled(bool enabled) async {
    if (_engine == null) return;
    await _engine!.enableLocalVideo(enabled);
    _emit(_state.copyWith(cameraEnabled: enabled));
  }

  Future<void> switchCamera() async {
    if (_engine == null) return;
    try {
      await _engine!.switchCamera();
    } catch (e) {
      _log.warn('switchCamera failed: $e');
    }
  }

  Future<void> _disposeEngine() async {
    try {
      await _engine?.release();
    } catch (e) {
      _log.warn('engine.release threw: $e');
    }
    _engine = null;
  }

  Future<void> dispose() async {
    await leave();
    await _controller.close();
  }
}

/// The service has internal lifecycle (engine init + dispose) — we want a
/// **fresh** instance per call so a previous session can't leak its state.
/// The CallScreen creates it via `ref.read(agoraCallServiceProvider)` and
/// invalidates it on dispose.
final agoraCallServiceProvider = Provider<AgoraCallService>((ref) {
  final service = AgoraCallService();
  ref.onDispose(service.dispose);
  return service;
});
