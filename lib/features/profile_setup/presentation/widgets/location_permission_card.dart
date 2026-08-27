import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_spacing.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../core/services/location_service.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../../shared/widgets/app_button.dart';
import '../providers/profile_setup_controller.dart';

/// Asks for location at the end of signup, where it can be explained.
///
/// It used to be asked at the first tap on "Lancer un date", stacked on top
/// of the camera and microphone prompts — three system dialogs in a row, the
/// first of them with no context at all. Here it is one dialog, after a
/// sentence saying what it is for.
///
/// It is a hard requirement, not a nicety: `find_best_live_candidate_v1`
/// rejects a caller whose `profiles.location` is null, so a user who declines
/// would join the queue and never match, with nothing on screen explaining
/// why. Better to be honest about it now than to fail silently later.
class LocationPermissionCard extends ConsumerStatefulWidget {
  const LocationPermissionCard({super.key});

  @override
  ConsumerState<LocationPermissionCard> createState() =>
      _LocationPermissionCardState();
}

class _LocationPermissionCardState
    extends ConsumerState<LocationPermissionCard> {
  LocationPermission? _status;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _readCurrent();
  }

  /// Someone reinstalling, or coming back through signup, may already have
  /// granted this. Asking them to tap a button that opens no dialog would
  /// look broken, so the card resolves itself on mount.
  Future<void> _readCurrent() async {
    final status = await LocationService.instance.currentPermissionStatus();
    if (!mounted) return;
    setState(() => _status = status);
    if (_granted(status)) _record(true);
  }

  static bool _granted(LocationPermission? p) =>
      p == LocationPermission.always || p == LocationPermission.whileInUse;

  void _record(bool granted) => ref
      .read(profileSetupControllerProvider.notifier)
      .setLocationGranted(granted);

  Future<void> _request() async {
    setState(() => _busy = true);
    final status = await LocationService.instance.requestPermission();
    if (!mounted) return;
    setState(() {
      _status = status;
      _busy = false;
    });
    // Only a real grant counts. A dismissed dialog leaves the step invalid.
    _record(_granted(status));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final granted = _granted(_status);
    final blocked = _status == LocationPermission.deniedForever;

    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: AppRadius.brLg,
        border: Border.all(
          color: granted ? AppColors.sage : AppColors.hairline,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                granted
                    ? Icons.check_circle_rounded
                    : Icons.location_on_outlined,
                color: granted ? AppColors.sage : AppColors.bordeaux,
                size: 22,
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  granted
                      ? l10n.locationSignupGranted
                      : l10n.locationSignupTitle,
                  style: AppTypography.bodyStrong,
                ),
              ),
            ],
          ),
          if (!granted) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              blocked ? l10n.locationSignupBlocked : l10n.locationSignupBody,
              style: AppTypography.caption.copyWith(
                color: AppColors.textSecondary,
                height: 1.35,
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            AppButton(
              label: blocked
                  ? l10n.locationSignupOpenSettings
                  : l10n.locationSignupCta,
              icon: blocked
                  ? Icons.settings_outlined
                  : Icons.my_location_rounded,
              isLoading: _busy,
              onPressed: _busy
                  ? null
                  : () async {
                      if (blocked) {
                        // iOS only shows its dialog once per install. After a
                        // hard refusal the only way back is Settings — and we
                        // re-read on return, so the card unlocks itself.
                        await Geolocator.openAppSettings();
                        await _readCurrent();
                      } else {
                        await _request();
                      }
                    },
            ),
          ],
        ],
      ),
    );
  }
}
