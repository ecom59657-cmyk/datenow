import 'dart:async';

import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/app_routes.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../core/config/app_config.dart';
import '../../../core/config/env.dart';
import '../../../core/utils/extensions.dart';
import '../../../core/utils/logger.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/app_scaffold.dart';
import '../../../shared/widgets/glass_card.dart';
import '../../auth/presentation/providers/auth_provider.dart';
import '../../matching/presentation/providers/active_match_provider.dart';
import '../../profile_setup/presentation/widgets/blurred_avatar.dart';
import '../data/agora_token_repository.dart';
import '../domain/agora_token.dart';
import '../services/agora_call_service.dart';

/// Live 5-minute call screen.
///
/// Two modes wired up:
/// - **Agora** when `AGORA_APP_ID` + Supabase are configured AND the token
///   Edge Function returns a valid token. Real audio/video, real
///   controls.
/// - **Mock** otherwise (no Agora env, token fetch fails, or running on
///   an unsupported platform). Same countdown + controls, but the peer
///   avatar stays blurred.
///
/// Either way, the screen owns the 5-minute timer and pushes the user to
/// `/post-call` when the call ends.
class CallScreen extends ConsumerStatefulWidget {
  const CallScreen({super.key});

  @override
  ConsumerState<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends ConsumerState<CallScreen> {
  static const _log = AppLogger('CallScreen');

  late final DateTime _start;
  Duration _remaining = AppConfig.maxCallDuration;
  Timer? _ticker;

  bool _micOn = true;
  bool _videoOn = true;

  /// `true` once we've decided real Agora is in play. Stays `false` for
  /// the fallback path (Env not configured, token fetch error).
  bool _agoraActive = false;
  StreamSubscription<AgoraCallState>? _agoraSub;
  AgoraCallState _agoraState = const AgoraCallState();

  @override
  void initState() {
    super.initState();
    _start = DateTime.now();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  Future<void> _bootstrap() async {
    if (!Env.agoraConfigured) {
      _log.info('Agora not configured — running in mock mode.');
      return;
    }

    final selfId = ref.read(currentUserProvider)?.id;
    final match = ref.read(activeMatchProvider);
    if (selfId == null || match == null) {
      _log.warn('Missing self id or active match — falling back to mock.');
      return;
    }

    final channel = AgoraTokenRepository.channelNameFor(
      selfId,
      match.candidate.userId,
    );
    final uid = AgoraTokenRepository.uidFromUserId(selfId);

    AgoraToken token;
    try {
      token = await ref
          .read(agoraTokenRepositoryProvider)
          .fetchToken(channelName: channel, uid: uid);
    } catch (e, st) {
      _log.error('Token fetch failed — staying in mock mode.', e, st);
      if (mounted) {
        context.showSnack(AppLocalizations.of(context).callTokenError);
      }
      return;
    }

    final service = ref.read(agoraCallServiceProvider);
    _agoraSub = service.stream.listen((state) {
      if (!mounted) return;
      setState(() => _agoraState = state);
    });

    try {
      await service.join(token);
      if (!mounted) return;
      setState(() => _agoraActive = true);
    } catch (e, st) {
      _log.error('Engine join failed — mock fallback.', e, st);
    }
  }

  void _tick() {
    final elapsed = DateTime.now().difference(_start);
    final r = AppConfig.maxCallDuration - elapsed;
    if (r.isNegative) {
      _ticker?.cancel();
      _endCall();
      return;
    }
    setState(() => _remaining = r);
  }

  Future<void> _toggleMic() async {
    final next = !_micOn;
    setState(() => _micOn = next);
    if (_agoraActive) {
      await ref.read(agoraCallServiceProvider).setMicMuted(!next);
    }
  }

  Future<void> _toggleVideo() async {
    final next = !_videoOn;
    setState(() => _videoOn = next);
    if (_agoraActive) {
      await ref.read(agoraCallServiceProvider).setCameraEnabled(next);
    }
  }

  Future<void> _switchCamera() async {
    if (!_agoraActive) return;
    await ref.read(agoraCallServiceProvider).switchCamera();
  }

  Future<void> _endCall() async {
    if (!mounted) return;
    if (_agoraActive) {
      await ref.read(agoraCallServiceProvider).leave();
    }
    if (!mounted) return;
    // Replace the call route with the post-call screen so back-navigation
    // doesn't bounce the user back into the (now ended) call.
    context.pushReplacementNamed(AppRoute.postCall.name);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _agoraSub?.cancel();
    // The service disposes itself via Riverpod onDispose when the provider
    // is invalidated, but to be safe we also fire leave() here. It's
    // idempotent.
    if (_agoraActive) {
      ref.read(agoraCallServiceProvider).leave();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final progress = _remaining.inSeconds /
        AppConfig.maxCallDuration.inSeconds.clamp(1, 1 << 30);

    return AppScaffold(
      glowIntensity: 0.6,
      body: Column(
        children: [
          const SizedBox(height: AppSpacing.md),
          _TopBar(
            remaining: _remaining,
            progress: progress,
            timeLeftLabel: l10n.callTimeLeft,
            liveLabel: l10n.callLive,
          ),
          const SizedBox(height: AppSpacing.lg),
          Expanded(
            child: _CallStage(
              agoraActive: _agoraActive,
              agoraState: _agoraState,
              showDemoNotice: !Env.agoraConfigured,
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          _Controls(
            micOn: _micOn,
            videoOn: _videoOn,
            agoraActive: _agoraActive,
            micLabel: _micOn ? l10n.callMute : l10n.callUnmute,
            videoLabel: _videoOn ? l10n.callVideo : l10n.callVideoOff,
            switchLabel: l10n.callSwitchCamera,
            endLabel: l10n.callEnd,
            onMicToggle: _toggleMic,
            onVideoToggle: _toggleVideo,
            onSwitchCamera: _switchCamera,
            onEnd: _endCall,
          ),
          const SizedBox(height: AppSpacing.md),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// The stage: real video tiles when Agora is up, blurred mock otherwise.
// ---------------------------------------------------------------------------

class _CallStage extends ConsumerWidget {
  const _CallStage({
    required this.agoraActive,
    required this.agoraState,
    required this.showDemoNotice,
  });

  final bool agoraActive;
  final AgoraCallState agoraState;
  final bool showDemoNotice;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final match = ref.watch(activeMatchProvider);
    final candidate = match?.candidate;
    final name = candidate?.firstName ?? 'Anonymous';
    final age = candidate?.age;
    final dist = match?.distanceKm;

    return GlassCard(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            children: [
              const SizedBox(height: AppSpacing.lg),
              SizedBox(
                height: 220,
                width: 220,
                child: agoraActive
                    ? _AgoraRemoteVideo(state: agoraState, name: name)
                    : const BlurredAvatar(size: 200)
                        .animate(onPlay: (c) => c.repeat(reverse: true))
                        .scaleXY(
                          duration: 1800.ms,
                          begin: 1,
                          end: 1.04,
                          curve: Curves.easeInOut,
                        ),
              ),
              const SizedBox(height: AppSpacing.lg),
              Text(
                age != null ? '$name, $age' : name,
                style: AppTypography.h2,
              ),
              const SizedBox(height: 4),
              Text(
                dist != null ? '$dist km · live' : 'live',
                style: AppTypography.body.copyWith(
                  color: AppColors.textSecondary,
                ),
              ),
              if (agoraActive && agoraState.remoteUid == null) ...[
                const SizedBox(height: AppSpacing.sm),
                Text(
                  l10n.callWaitingPeer(name),
                  style: AppTypography.caption.copyWith(
                    color: AppColors.textTertiary,
                  ),
                ),
              ],
            ],
          ),
          Column(
            children: [
              if (showDemoNotice)
                _DemoNotice(message: l10n.callDemoNotice)
              else if (agoraActive)
                _LocalVideoPip(state: agoraState),
              const SizedBox(height: AppSpacing.sm),
              Text(
                l10n.callReminder,
                textAlign: TextAlign.center,
                style: AppTypography.caption.copyWith(
                  color: AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AgoraRemoteVideo extends ConsumerWidget {
  const _AgoraRemoteVideo({required this.state, required this.name});

  final AgoraCallState state;
  final String name;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final engine = ref.read(agoraCallServiceProvider).engine;
    final remoteUid = state.remoteUid;

    if (engine == null || remoteUid == null) {
      // Waiting for the peer to join — blurred placeholder keeps the
      // privacy rule (no photo) intact.
      return const BlurredAvatar(size: 200);
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: AgoraVideoView(
        controller: VideoViewController.remote(
          rtcEngine: engine,
          canvas: VideoCanvas(uid: remoteUid),
          connection: const RtcConnection(channelId: ''),
        ),
      ),
    );
  }
}

class _LocalVideoPip extends ConsumerWidget {
  const _LocalVideoPip({required this.state});

  final AgoraCallState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final engine = ref.read(agoraCallServiceProvider).engine;
    if (engine == null) return const SizedBox.shrink();
    if (!state.cameraEnabled) {
      return Container(
        width: 96,
        height: 128,
        decoration: BoxDecoration(
          color: AppColors.surfaceElevated,
          borderRadius: AppRadius.brMd,
          border: Border.all(color: AppColors.hairline),
        ),
        alignment: Alignment.center,
        child: const Icon(
          Icons.videocam_off_rounded,
          color: AppColors.textTertiary,
        ),
      );
    }

    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        width: 96,
        height: 128,
        decoration: BoxDecoration(
          borderRadius: AppRadius.brMd,
          border: Border.all(color: AppColors.hairline),
        ),
        clipBehavior: Clip.antiAlias,
        child: AgoraVideoView(
          controller: VideoViewController(
            rtcEngine: engine,
            canvas: const VideoCanvas(uid: 0),
          ),
        ),
      ),
    );
  }
}

class _DemoNotice extends StatelessWidget {
  const _DemoNotice({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.12),
        borderRadius: AppRadius.brSm,
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          const Icon(Icons.info_outline_rounded,
              color: AppColors.warning, size: 18),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              message,
              style: AppTypography.caption.copyWith(
                color: AppColors.warning,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Top bar + Controls (unchanged from before, but Controls grew a
// "switch camera" tile + only enables it in real Agora mode).
// ---------------------------------------------------------------------------

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.remaining,
    required this.progress,
    required this.timeLeftLabel,
    required this.liveLabel,
  });

  final Duration remaining;
  final double progress;
  final String timeLeftLabel;
  final String liveLabel;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      child: Row(
        children: [
          SizedBox(
            width: 36,
            height: 36,
            child: Stack(
              alignment: Alignment.center,
              children: [
                SizedBox(
                  width: 36,
                  height: 36,
                  child: CircularProgressIndicator(
                    value: progress,
                    strokeWidth: 3,
                    backgroundColor: AppColors.hairline,
                    valueColor:
                        const AlwaysStoppedAnimation(AppColors.brandPink),
                  ),
                ),
                const Icon(Icons.timer_rounded,
                    color: AppColors.textSecondary, size: 14),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(timeLeftLabel, style: AppTypography.caption),
                Text(
                  remaining.toMmSs(),
                  style: AppTypography.h3.copyWith(letterSpacing: 1),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.sm,
              vertical: 6,
            ),
            decoration: BoxDecoration(
              color: AppColors.online.withValues(alpha: 0.18),
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
                  liveLabel,
                  style: AppTypography.caption.copyWith(
                    color: AppColors.online,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({
    required this.micOn,
    required this.videoOn,
    required this.agoraActive,
    required this.micLabel,
    required this.videoLabel,
    required this.switchLabel,
    required this.endLabel,
    required this.onMicToggle,
    required this.onVideoToggle,
    required this.onSwitchCamera,
    required this.onEnd,
  });

  final bool micOn;
  final bool videoOn;
  final bool agoraActive;
  final String micLabel;
  final String videoLabel;
  final String switchLabel;
  final String endLabel;
  final VoidCallback onMicToggle;
  final VoidCallback onVideoToggle;
  final VoidCallback onSwitchCamera;
  final VoidCallback onEnd;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _CircleAction(
          icon: micOn ? Icons.mic_rounded : Icons.mic_off_rounded,
          label: micLabel,
          onTap: onMicToggle,
        ),
        _CircleAction(
          icon: videoOn ? Icons.videocam_rounded : Icons.videocam_off_rounded,
          label: videoLabel,
          onTap: onVideoToggle,
        ),
        if (agoraActive)
          _CircleAction(
            icon: Icons.cameraswitch_rounded,
            label: switchLabel,
            onTap: onSwitchCamera,
          ),
        _CircleAction(
          icon: Icons.call_end_rounded,
          label: endLabel,
          onTap: onEnd,
          danger: true,
        ),
      ],
    );
  }
}

class _CircleAction extends StatelessWidget {
  const _CircleAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.danger = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final color = danger ? AppColors.error : AppColors.surfaceElevated;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            customBorder: const CircleBorder(),
            child: Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color,
                border: Border.all(
                  color: danger
                      ? AppColors.error.withValues(alpha: 0.4)
                      : AppColors.hairline,
                ),
                boxShadow: danger
                    ? [
                        BoxShadow(
                          color: AppColors.error.withValues(alpha: 0.5),
                          blurRadius: 24,
                          offset: const Offset(0, 6),
                        ),
                      ]
                    : null,
              ),
              child: Icon(
                icon,
                color: danger ? Colors.white : AppColors.textPrimary,
                size: 24,
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(label, style: AppTypography.caption),
      ],
    );
  }
}
