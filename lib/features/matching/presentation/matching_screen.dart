import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/app_routes.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../shared/widgets/app_button.dart';
import '../../../shared/widgets/app_scaffold.dart';

/// Auto-match screen. UI-only for the MVP — the real match negotiation will
/// happen over Supabase realtime later. We simulate a successful match after
/// a few seconds so the user lands in the call screen.
class MatchingScreen extends StatefulWidget {
  const MatchingScreen({super.key});

  @override
  State<MatchingScreen> createState() => _MatchingScreenState();
}

class _MatchingScreenState extends State<MatchingScreen> {
  Timer? _simulator;
  int _step = 0;

  static const _messages = [
    'Finding someone compatible…',
    'Checking who\'s online near you…',
    'Confirming a match…',
  ];

  @override
  void initState() {
    super.initState();
    _simulator = Timer.periodic(const Duration(seconds: 1, milliseconds: 600),
        (timer) {
      if (_step >= _messages.length - 1) {
        timer.cancel();
        _goToCall();
        return;
      }
      setState(() => _step++);
    });
  }

  void _goToCall() {
    if (!mounted) return;
    context.pushReplacementNamed(AppRoute.call.name);
  }

  @override
  void dispose() {
    _simulator?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: () => context.pop(),
        ),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Spacer(flex: 2),
          const Center(child: _RippleAvatar()),
          const SizedBox(height: AppSpacing.xl),
          Text(
            'Matching you live',
            textAlign: TextAlign.center,
            style: AppTypography.h2,
          ),
          const SizedBox(height: AppSpacing.sm),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            child: Text(
              _messages[_step],
              key: ValueKey(_step),
              textAlign: TextAlign.center,
              style: AppTypography.body.copyWith(
                color: AppColors.textSecondary,
              ),
            ),
          ),
          const Spacer(flex: 3),
          AppButton(
            label: 'Cancel',
            variant: AppButtonVariant.secondary,
            onPressed: () => context.pop(),
          ),
          const SizedBox(height: AppSpacing.lg),
        ],
      ),
    );
  }
}

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
          for (var i = 0; i < 3; i++)
            _Ripple(delayMs: i * 600),
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
