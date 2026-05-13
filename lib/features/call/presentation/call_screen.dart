import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../core/config/app_config.dart';
import '../../../core/utils/extensions.dart';
import '../../../shared/widgets/app_scaffold.dart';
import '../../../shared/widgets/glass_card.dart';

/// Live call screen — placeholder UI for the 5-minute audio/video session.
/// Real WebRTC plumbing will replace this; the layout & countdown are what
/// the design team can already iterate on.
class CallScreen extends StatefulWidget {
  const CallScreen({super.key});

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  late final DateTime _start = DateTime.now();
  Duration _remaining = AppConfig.maxCallDuration;
  Timer? _ticker;
  bool _micOn = true;
  bool _videoOn = true;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
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

  void _endCall() {
    if (!mounted) return;
    context.pop();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final progress = _remaining.inSeconds /
        AppConfig.maxCallDuration.inSeconds.clamp(1, 1 << 30);

    return AppScaffold(
      glowIntensity: 0.6,
      body: Column(
        children: [
          const SizedBox(height: AppSpacing.md),
          _TopBar(remaining: _remaining, progress: progress),
          const SizedBox(height: AppSpacing.lg),
          Expanded(
            child: GlassCard(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    children: [
                      const SizedBox(height: AppSpacing.lg),
                      Container(
                        width: 120,
                        height: 120,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: AppColors.brandGradient,
                          boxShadow: [
                            BoxShadow(
                              color:
                                  AppColors.brandPink.withValues(alpha: 0.45),
                              blurRadius: 40,
                              spreadRadius: 4,
                            ),
                          ],
                        ),
                        child: const Icon(Icons.person_rounded,
                            color: Colors.white, size: 56),
                      )
                          .animate(onPlay: (c) => c.repeat(reverse: true))
                          .scaleXY(
                            duration: 1800.ms,
                            begin: 1,
                            end: 1.04,
                            curve: Curves.easeInOut,
                          ),
                      const SizedBox(height: AppSpacing.lg),
                      Text('Alex, 28', style: AppTypography.h2),
                      const SizedBox(height: 4),
                      Text(
                        '4 km away · Lives in Paris',
                        style: AppTypography.body.copyWith(
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                  Text(
                    'Be kind. Be curious. Have fun.',
                    style: AppTypography.caption.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          _Controls(
            micOn: _micOn,
            videoOn: _videoOn,
            onMicToggle: () => setState(() => _micOn = !_micOn),
            onVideoToggle: () => setState(() => _videoOn = !_videoOn),
            onEnd: _endCall,
          ),
          const SizedBox(height: AppSpacing.md),
        ],
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.remaining, required this.progress});

  final Duration remaining;
  final double progress;

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
                Text('Time left', style: AppTypography.caption),
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
                  'LIVE',
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
    required this.onMicToggle,
    required this.onVideoToggle,
    required this.onEnd,
  });

  final bool micOn;
  final bool videoOn;
  final VoidCallback onMicToggle;
  final VoidCallback onVideoToggle;
  final VoidCallback onEnd;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _CircleAction(
          icon: micOn ? Icons.mic_rounded : Icons.mic_off_rounded,
          label: micOn ? 'Mute' : 'Unmute',
          onTap: onMicToggle,
        ),
        _CircleAction(
          icon: videoOn ? Icons.videocam_rounded : Icons.videocam_off_rounded,
          label: videoOn ? 'Video' : 'Off',
          onTap: onVideoToggle,
        ),
        _CircleAction(
          icon: Icons.call_end_rounded,
          label: 'End',
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
