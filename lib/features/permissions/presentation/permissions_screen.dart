import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../app/router/app_routes.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../core/utils/logger.dart';
import '../../../shared/widgets/app_button.dart';
import '../../../shared/widgets/app_scaffold.dart';

/// Post-onboarding permissions screen.
///
/// Triggers the iOS native camera + microphone consent prompts at the
/// right moment — right after profile creation, before the user reaches
/// the matching/live flow. Without this screen the first prompt would
/// only fire at the call screen, mid-action, which is jarring.
///
/// Outcomes handled:
///   * granted        → navigate to home
///   * denied         → stay, let the user retry
///   * permanently denied / restricted → surface "Ouvrir les réglages"
///     so the user can re-enable via iOS Settings (deep link via
///     `openAppSettings()` → `UIApplication.openSettingsURLString`)
class PermissionsScreen extends ConsumerStatefulWidget {
  const PermissionsScreen({super.key});

  @override
  ConsumerState<PermissionsScreen> createState() => _PermissionsScreenState();
}

class _PermissionsScreenState extends ConsumerState<PermissionsScreen> {
  static const _log = AppLogger('Permissions');

  bool _busy = false;
  PermissionStatus _cam = PermissionStatus.denied;
  PermissionStatus _mic = PermissionStatus.denied;

  @override
  void initState() {
    super.initState();
    _refreshStatuses();
  }

  Future<void> _refreshStatuses() async {
    final cam = await Permission.camera.status;
    final mic = await Permission.microphone.status;
    if (!mounted) return;
    setState(() {
      _cam = cam;
      _mic = mic;
    });
    // Already granted from a previous session → don't make the user
    // tap through this screen again.
    if (cam.isGranted && mic.isGranted) {
      _log.info('Permissions already granted — skipping straight to home');
      _goHome();
    }
  }

  /// Triggers the native iOS popups. iOS only shows them once per app
  /// install — on subsequent calls the status comes back denied/permanently
  /// denied without a prompt. In that case we steer the user to Settings.
  Future<void> _request() async {
    if (_busy) return;
    setState(() => _busy = true);
    _log.info('Requesting camera + microphone');
    try {
      final results = await [
        Permission.camera,
        Permission.microphone,
      ].request();
      final cam = results[Permission.camera] ?? PermissionStatus.denied;
      final mic = results[Permission.microphone] ?? PermissionStatus.denied;
      _log.info('Result — cam=${cam.name} mic=${mic.name}');
      if (!mounted) return;
      setState(() {
        _cam = cam;
        _mic = mic;
      });
      if (cam.isGranted && mic.isGranted) {
        _goHome();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openSettings() async {
    _log.info('Opening iOS Settings for DateNow');
    await openAppSettings();
    // When the user comes back, re-check — they may have flipped the
    // toggles so we can advance immediately.
    if (mounted) await _refreshStatuses();
  }

  void _goHome() {
    if (!mounted) return;
    context.goNamed(AppRoute.home.name);
  }

  bool get _bothGranted => _cam.isGranted && _mic.isGranted;
  bool get _needsSettings =>
      _cam.isPermanentlyDenied ||
      _cam.isRestricted ||
      _mic.isPermanentlyDenied ||
      _mic.isRestricted;

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      glowIntensity: 0.7,
      body: SafeArea(
        child: Column(
            children: [
              const Spacer(flex: 2),
              _GlowingDuo()
                  .animate()
                  .scale(
                    duration: 420.ms,
                    begin: const Offset(0.85, 0.85),
                    end: const Offset(1, 1),
                    curve: Curves.easeOutBack,
                  )
                  .fadeIn(duration: 400.ms),
              const SizedBox(height: AppSpacing.xl),
              Text(
                'DateNow fonctionne en vidéo live',
                textAlign: TextAlign.center,
                style: AppTypography.h1,
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                'Pour vivre tes dates de 5 minutes, autorise DateNow à '
                'utiliser ta caméra et ton micro.',
                textAlign: TextAlign.center,
                style: AppTypography.body.copyWith(
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: AppSpacing.xl),
              _PermRow(
                icon: Icons.videocam_rounded,
                label: 'Caméra',
                status: _cam,
              ),
              const SizedBox(height: AppSpacing.sm),
              _PermRow(
                icon: Icons.mic_rounded,
                label: 'Micro',
                status: _mic,
              ),
              const Spacer(flex: 3),
              if (_needsSettings) ...[
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                  child: Text(
                    'iOS a bloqué la demande. Ouvre les réglages pour '
                    'activer Caméra et Micro pour DateNow.',
                    textAlign: TextAlign.center,
                    style: AppTypography.caption.copyWith(
                      color: AppColors.textTertiary,
                    ),
                  ),
                ),
                AppButton(
                  label: 'Ouvrir les réglages',
                  icon: Icons.settings_rounded,
                  size: AppButtonSize.large,
                  onPressed: _busy ? null : _openSettings,
                ),
              ] else ...[
                AppButton(
                  label: _bothGranted
                      ? 'Continuer'
                      : 'Autoriser caméra et micro',
                  icon: Icons.lock_open_rounded,
                  size: AppButtonSize.large,
                  isLoading: _busy,
                  onPressed: _busy
                      ? null
                      : (_bothGranted ? _goHome : _request),
                ),
              ],
              const SizedBox(height: AppSpacing.sm),
              TextButton(
                onPressed: _busy ? null : _goHome,
                child: Text(
                  'Plus tard',
                  style: AppTypography.body.copyWith(
                    color: AppColors.textTertiary,
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
            ],
          ),
      ),
    );
  }
}

class _PermRow extends StatelessWidget {
  const _PermRow({
    required this.icon,
    required this.label,
    required this.status,
  });

  final IconData icon;
  final String label;
  final PermissionStatus status;

  @override
  Widget build(BuildContext context) {
    final (trailIcon, trailColor, trailText) = switch (status) {
      _ when status.isGranted => (
          Icons.check_circle_rounded,
          AppColors.online,
          'Autorisé',
        ),
      _ when status.isPermanentlyDenied || status.isRestricted => (
          Icons.lock_rounded,
          AppColors.error,
          'Bloqué',
        ),
      _ => (
          Icons.radio_button_unchecked_rounded,
          AppColors.textTertiary,
          'À autoriser',
        ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm + 2,
      ),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.hairline),
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.brandPink.withValues(alpha: 0.16),
            ),
            child: Icon(icon, color: AppColors.brandPink, size: 20),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text(
              label,
              style: AppTypography.body.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Icon(trailIcon, color: trailColor, size: 18),
          const SizedBox(width: 6),
          Text(
            trailText,
            style: AppTypography.caption.copyWith(
              color: trailColor,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

/// Two overlapping glowing dots — one pink for camera, one violet for mic.
/// Tiny visual cue tying the screen to the rest of the brand language.
class _GlowingDuo extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 200,
      height: 130,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned(
            left: 30,
            child: _glow(AppColors.brandPink, Icons.videocam_rounded),
          ),
          Positioned(
            right: 30,
            child: _glow(AppColors.brandViolet, Icons.mic_rounded),
          ),
        ],
      ),
    );
  }

  Widget _glow(Color color, IconData icon) {
    return Container(
      width: 88,
      height: 88,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [color.withValues(alpha: 0.9), color.withValues(alpha: 0)],
        ),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.55),
            blurRadius: 38,
            spreadRadius: 6,
          ),
        ],
      ),
      child: Icon(icon, color: Colors.white, size: 32),
    );
  }
}
