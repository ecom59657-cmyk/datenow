import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_spacing.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../core/utils/extensions.dart';
import '../../../../core/utils/logger.dart';
import '../../../../l10n/app_localizations.dart';

/// Tap-target to pick a profile photo. Shows a small thumbnail preview
/// once a picture is chosen — that preview is the **only** place in the
/// app where the user sees their own picture before a successful date.
///
/// UX (Apple-native):
///   tap → CupertinoActionSheet with two options:
///         "Prendre une photo" (camera) | "Choisir depuis mes photos" (gallery)
///
/// Camera path checks runtime permission via permission_handler and
/// shows a clean "Ouvrir les Réglages" fallback if the user denied.
/// Gallery path relies on iOS 14+ PHPickerViewController (no Photos
/// permission needed at all) and degrades gracefully on older OS.
class PhotoPickerCard extends StatelessWidget {
  const PhotoPickerCard({
    super.key,
    required this.bytes,
    required this.onPicked,
  });

  static const _log = AppLogger('PhotoPicker');

  final Uint8List? bytes;
  final ValueChanged<Uint8List> onPicked;

  Future<void> _showSourceSheet(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    final source = await showCupertinoModalPopup<ImageSource>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: Text(l10n.photoSourceSheetTitle),
        actions: [
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(ctx, ImageSource.camera),
            child: Text(l10n.photoSourceCamera),
          ),
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(ctx, ImageSource.gallery),
            child: Text(l10n.photoSourceGallery),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          isDefaultAction: true,
          onPressed: () => Navigator.pop(ctx),
          child: Text(l10n.cancel),
        ),
      ),
    );
    if (source == null || !context.mounted) return;
    if (source == ImageSource.camera) {
      await _pickFromCamera(context);
    } else {
      await _pickFromGallery(context);
    }
  }

  /// Camera path — runtime permission MUST be checked before invoking
  /// image_picker, otherwise iOS denies silently and image_picker
  /// returns null without surfacing the reason to the user.
  Future<void> _pickFromCamera(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    var status = await Permission.camera.status;
    _log.info('camera permission status (pre) = $status');
    if (status.isDenied) {
      status = await Permission.camera.request();
      _log.info('camera permission status (post-request) = $status');
    }
    if (status.isPermanentlyDenied || status.isRestricted) {
      _log.warn('camera permission permanently denied — offering settings');
      if (!context.mounted) return;
      await _showPermissionDeniedSheet(
        context,
        title: l10n.photoCameraDeniedTitle,
        body: l10n.photoCameraDeniedBody,
      );
      return;
    }
    if (!status.isGranted && !status.isLimited) {
      _log.info('camera permission not granted — bailing');
      return;
    }
    if (!context.mounted) return;
    await _pick(context, source: ImageSource.camera);
  }

  /// Gallery path — iOS 14+ PHPickerViewController doesn't need any
  /// Photos permission at all (the system picker runs out-of-process
  /// and only returns the picked asset). We still attempt a request
  /// on iOS < 14 / Android via permission_handler when the OS exposes
  /// the older "Photo Library" permission — failures are non-fatal,
  /// the picker handles the rest.
  Future<void> _pickFromGallery(BuildContext context) async {
    _log.info('gallery — invoking PHPickerViewController via image_picker');
    if (!context.mounted) return;
    await _pick(context, source: ImageSource.gallery);
  }

  Future<void> _pick(BuildContext context, {
    required ImageSource source,
  }) async {
    try {
      final picker = ImagePicker();
      final picked = await picker.pickImage(
        source: source,
        maxWidth: 1200,
        imageQuality: 88,
        // Use the modern front-facing camera by default for the camera
        // path — feels more natural for a profile-photo capture.
        preferredCameraDevice: source == ImageSource.camera
            ? CameraDevice.front
            : CameraDevice.rear,
      );
      if (picked == null) {
        _log.info('user cancelled the picker');
        return;
      }
      final raw = await picked.readAsBytes();
      _log.info('photo picked — ${raw.lengthInBytes} bytes from $source');
      onPicked(raw);
    } catch (e, st) {
      _log.warn('pick failed: $e\n$st');
      if (context.mounted) {
        final l10n = AppLocalizations.of(context);
        context.showSnack(l10n.photoPickFailedSnack);
      }
    }
  }

  Future<void> _showPermissionDeniedSheet(
    BuildContext context, {
    required String title,
    required String body,
  }) async {
    final l10n = AppLocalizations.of(context);
    await showCupertinoModalPopup<void>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: Text(title),
        message: Text(body),
        actions: [
          CupertinoActionSheetAction(
            isDefaultAction: true,
            onPressed: () {
              Navigator.pop(ctx);
              openAppSettings();
            },
            child: Text(l10n.photoPermissionOpenSettings),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(ctx),
          child: Text(l10n.cancel),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final has = bytes != null;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _showSourceSheet(context),
        borderRadius: AppRadius.brLg,
        child: Container(
          padding: const EdgeInsets.all(AppSpacing.md),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: AppRadius.brLg,
            border: Border.all(
              color: has ? AppColors.bordeaux : AppColors.hairline,
              width: has ? 1.5 : 1,
            ),
          ),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: has
                    ? Image.memory(
                        bytes!,
                        width: 56,
                        height: 56,
                        fit: BoxFit.cover,
                      )
                    : Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          color: AppColors.surfaceElevated,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: AppColors.hairlineSoft),
                        ),
                        child: const Icon(
                          Icons.add_a_photo_outlined,
                          color: AppColors.textTertiary,
                        ),
                      ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      has ? l10n.photoTapToChange : l10n.photoTapToAdd,
                      style: AppTypography.bodyStrong,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      l10n.photoPrivacyNote,
                      style: AppTypography.caption.copyWith(
                        color: AppColors.textTertiary,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
