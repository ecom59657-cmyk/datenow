import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../../../app/theme/app_colors.dart';
import '../../../../../app/theme/app_spacing.dart';
import '../../../../../app/theme/app_typography.dart';
import '../../../../profile_moderation/domain/photo_moderation_status.dart';

/// One slot in the [PhotoGrid]: either the user's photo thumbnail (with a
/// menu trigger) or an empty "add" placeholder.
///
/// Filled tiles also surface the photo's moderation status :
///   * `approved` (or `null` = grandfathered legacy photo) → no overlay,
///     standard display.
///   * `rejected`                       → greyscale image + dark wash + red
///                                        "Photo refusée" badge at the bottom.
///                                        Communicates that re-uploading is
///                                        the only way out.
///   * `pending` / `analyzing` /
///     `manual_review`                  → discreet dark "En vérification…"
///                                        badge at the bottom. Image stays
///                                        in full colour so the user can
///                                        still recognise their selfie.
class PhotoTile extends StatelessWidget {
  const PhotoTile.add({super.key, required this.onTap, this.label})
      : bytes = null,
        loading = false,
        status = null,
        _isUploading = false;

  const PhotoTile.filled({
    super.key,
    required Uint8List this.bytes,
    required this.onTap,
    this.status,
  })  : label = null,
        loading = false,
        _isUploading = false;

  const PhotoTile.loading({super.key})
      : bytes = null,
        onTap = null,
        label = null,
        loading = true,
        status = null,
        _isUploading = false;

  /// Tinder/Hinge-style optimistic tile : rendered the instant the
  /// user picks a photo (typically <200 ms after pick), BEFORE the
  /// upload + insert + Edge Function chain has finished. Reuses the
  /// picked bytes locally so no storage round-trip is on the critical
  /// rendering path. Visually : full-colour image with a subtle dark
  /// wash, a centered spinner, and an "Analyse…" badge at the bottom.
  /// The menu trigger is intentionally hidden — a half-uploaded photo
  /// cannot be deleted or replaced.
  const PhotoTile.optimistic({super.key, required Uint8List this.bytes})
      : onTap = null,
        label = null,
        loading = false,
        status = null,
        _isUploading = true;

  final Uint8List? bytes;
  final VoidCallback? onTap;
  final String? label;
  final bool loading;

  /// Per-photo moderation status. `null` is treated as `approved`
  /// (grandfathered photos from before the moderation pipeline existed
  /// must keep rendering normally — the SQL grandfather migration set
  /// them to `approved`, but the UI must not crash if the status
  /// fetch failed and we got `null`).
  final PhotoModerationStatus? status;

  /// True for the .optimistic ctor. Drives the upload-time visuals
  /// (centered spinner + "Analyse…" badge + hidden menu trigger).
  final bool _isUploading;

  bool get _isAdd => bytes == null && !loading;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return _baseBox(
        child: const Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation(AppColors.brandPink),
            ),
          ),
        ),
      );
    }

    if (_isAdd) {
      return Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: AppRadius.brMd,
          child: _baseBox(
            dashed: true,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.add_a_photo_outlined,
                    color: AppColors.textTertiary),
                if (label != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    label!,
                    textAlign: TextAlign.center,
                    style: AppTypography.caption.copyWith(
                      color: AppColors.textTertiary,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: AppRadius.brMd,
        child: ClipRRect(
          borderRadius: AppRadius.brMd,
          child: Stack(
            fit: StackFit.expand,
            children: [
              _imageWithStatusOverlay(),
              // Menu trigger stays on top of any overlay so the user
              // can always tap it (re-upload via "Replace", or delete).
              // Hidden for optimistic tiles — a half-uploaded photo
              // has no row in user_photos yet, so delete / replace
              // would refer to nothing.
              if (!_isUploading)
                Positioned(
                  top: 6,
                  right: 6,
                  child: Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.55),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.more_horiz_rounded,
                        size: 18, color: Colors.white),
                  ),
                ),
              // Status badge floats at the bottom, OVER any overlay
              // wash, never under the menu trigger.
              if (_statusBadge() != null)
                Positioned(
                  left: 6,
                  right: 6,
                  bottom: 6,
                  child: _statusBadge()!,
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Renders the image with the right colour treatment :
  ///   * optimistic (uploading)               → subtle dark wash + centred
  ///                                              white spinner so the
  ///                                              user instantly sees the
  ///                                              tile is in flight
  ///   * normal (approved / null)              → straight Image.memory
  ///   * pending / analyzing / manual_review   → straight Image.memory
  ///                                              (no greyscale — user
  ///                                              must still recognise it)
  ///   * rejected                              → greyscale + dark wash
  Widget _imageWithStatusOverlay() {
    final img = Image.memory(bytes!, fit: BoxFit.cover);
    if (_isUploading) {
      return Stack(fit: StackFit.expand, children: [
        ColorFiltered(
          // Slight darken so the white spinner reads against light
          // photos. Does NOT use BlendMode.saturation so the user
          // still recognises the photo they just picked.
          colorFilter: ColorFilter.mode(
            Colors.black.withValues(alpha: 0.30),
            BlendMode.darken,
          ),
          child: img,
        ),
        const Center(
          child: SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(
              strokeWidth: 2.5,
              valueColor: AlwaysStoppedAnimation(Colors.white),
            ),
          ),
        ),
      ]);
    }
    if (status == PhotoModerationStatus.rejected) {
      return Stack(fit: StackFit.expand, children: [
        ColorFiltered(
          // Luminance-weighted greyscale (Rec. 709). Last row keeps
          // alpha at 1, R/G/B all read from the same weighted sum.
          colorFilter: const ColorFilter.matrix(<double>[
            0.2126, 0.7152, 0.0722, 0, 0,
            0.2126, 0.7152, 0.0722, 0, 0,
            0.2126, 0.7152, 0.0722, 0, 0,
            0,      0,      0,      1, 0,
          ]),
          child: img,
        ),
        // Subtle dark wash on top so the red badge reads clearly.
        Container(color: Colors.black.withValues(alpha: 0.30)),
      ]);
    }
    return img;
  }

  /// The status badge widget for the current [status], or `null` when
  /// no badge should render (approved or unknown).
  Widget? _statusBadge() {
    // Optimistic upload — wording matches the brief ("Analyse…"),
    // distinct from the server-side "En vérification…" so the user
    // can intuit the flow : upload first, then server check.
    if (_isUploading) {
      return _StatusBadge(
        label: 'Analyse…',
        background: Colors.black.withValues(alpha: 0.65),
        icon: Icons.cloud_upload_rounded,
      );
    }
    switch (status) {
      case null:
      case PhotoModerationStatus.approved:
        return null;
      case PhotoModerationStatus.rejected:
        return _StatusBadge(
          label: 'Photo refusée',
          background: AppColors.error,
          icon: Icons.block_rounded,
        );
      case PhotoModerationStatus.pending:
      case PhotoModerationStatus.analyzing:
      case PhotoModerationStatus.manualReview:
        return _StatusBadge(
          label: 'En vérification…',
          background: Colors.black.withValues(alpha: 0.65),
          icon: Icons.hourglass_top_rounded,
        );
    }
  }

  Widget _baseBox({required Widget child, bool dashed = false}) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadius.brMd,
        border: Border.all(
          color: AppColors.hairline,
          width: dashed ? 1 : 1,
          style: dashed ? BorderStyle.solid : BorderStyle.solid,
          // (Flutter ships no native dashed border. The slight tint
          // difference with the filled tiles is enough visual distinction.)
        ),
      ),
      child: child,
    );
  }
}

/// Compact pill that surfaces the moderation status. Sits at the
/// bottom of a [PhotoTile] above any greyscale wash.
class _StatusBadge extends StatelessWidget {
  const _StatusBadge({
    required this.label,
    required this.background,
    required this.icon,
  });

  final String label;
  final Color background;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: Colors.white),
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
                fontSize: 11,
                letterSpacing: 0.2,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
