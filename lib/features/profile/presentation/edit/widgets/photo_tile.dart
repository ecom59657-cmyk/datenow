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
              // wash, never under the menu trigger. Wrapped in an
              // AnimatedSwitcher so the badge transitions
              //   uploading → pending → approved/rejected/manualReview
              // cross-fade smoothly (300 ms) instead of swapping on a
              // single frame — testers reported the abrupt change felt
              // brittle.
              Positioned(
                left: 6,
                right: 6,
                bottom: 6,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  switchInCurve: Curves.easeOut,
                  switchOutCurve: Curves.easeIn,
                  child: _statusBadge() != null
                      ? KeyedSubtree(
                          key: ValueKey('badge:${_badgeKey()}'),
                          child: _statusBadge()!,
                        )
                      : const SizedBox.shrink(
                          key: ValueKey('badge:none'),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// True for every state where moderation analysis is ongoing —
  /// keeps the wash + spinner + dark badge visually continuous from
  /// the optimistic upload through the server-side `pending` /
  /// `analyzing` window. Without this the transition felt sec to
  /// testers (3 simultaneous visual changes : wash off + spinner off
  /// + badge swap).
  bool get _isAnalysisInProgress =>
      _isUploading ||
      // null = status unknown (provider loading OR new upload row not
      // yet picked up by myPhotoStatusesProvider). Conservative : treat
      // as "still being checked" — never as "approved by default" — so
      // a freshly uploaded photo NEVER flashes "Validée" before
      // Google Vision has actually said so. Grandfathered photos
      // already have DB status='approved' (set by the SQL migration)
      // and hit the explicit `approved` switch arm, so they are NOT
      // affected by this null branch.
      status == null ||
      status == PhotoModerationStatus.pending ||
      status == PhotoModerationStatus.analyzing;

  /// Discriminator key for the AnimatedSwitcher around the badge.
  /// Each distinct (uploading vs status enum value) gets its own key
  /// so the switcher knows when to cross-fade. Two consecutive
  /// renders with the same key are treated as "no change" → no
  /// animation, which is what we want when the status hasn't moved.
  String _badgeKey() {
    if (_isUploading) return 'uploading';
    return status?.name ?? 'none';
  }

  /// Renders the image with the right colour treatment :
  ///   * analysis in progress                  → subtle dark wash +
  ///     (optimistic, pending, analyzing)        centred white spinner
  ///                                              so the tile reads as
  ///                                              "actively being checked"
  ///                                              the WHOLE time
  ///   * rejected                              → greyscale + dark wash
  ///   * approved / manualReview / null        → straight Image.memory
  ///                                              (terminal states; the
  ///                                              status badge alone
  ///                                              tells the story)
  Widget _imageWithStatusOverlay() {
    final img = Image.memory(bytes!, fit: BoxFit.cover);
    if (_isAnalysisInProgress) {
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

  /// The status badge widget for the current [status], or `null`
  /// when no badge should render (only for the unknown-status case
  /// — every known PhotoModerationStatus now has its own badge so
  /// the user is always told exactly where the photo stands).
  ///
  /// Stable, persistent design : the "Validée" badge stays for the
  /// life of the tile (no fade-out timer). The user must be able to
  /// glance at their grid and immediately see which photos are
  /// usable.
  Widget? _statusBadge() {
    // Optimistic upload — distinct wording ("Analyse…") so the user
    // can intuit the flow : upload first, then server check
    // ("En vérification…"), then the final verdict.
    if (_isUploading) {
      return _StatusBadge(
        label: 'Analyse…',
        background: Colors.black.withValues(alpha: 0.65),
        icon: Icons.cloud_upload_rounded,
      );
    }
    switch (status) {
      case PhotoModerationStatus.approved:
        // Only an EXPLICIT approved status — either from the Edge
        // Function verdict or from the SQL grandfather migration —
        // earns the green "Validée" badge. Never inferred from null
        // or fallback. The previous "null defaults to Validée"
        // shortcut caused a "Validée → À vérifier" reversal on new
        // uploads (the row was inserted with status=pending but
        // myPhotoStatusesProvider had not re-fetched yet, so the
        // tile briefly mapped to null → green, then crossed back to
        // orange once the real verdict landed). That read as the app
        // de-validating a previously validated photo, which is the
        // worst possible UX.
        return const _StatusBadge(
          label: 'Validée',
          background: AppColors.success,
          icon: Icons.verified_rounded,
        );
      case PhotoModerationStatus.rejected:
        return const _StatusBadge(
          label: 'Photo refusée',
          background: AppColors.error,
          icon: Icons.block_rounded,
        );
      case null:
      case PhotoModerationStatus.pending:
      case PhotoModerationStatus.analyzing:
        // Conservative : null status (provider loading OR new upload
        // row not yet picked up) shares the same "En vérification…"
        // badge as the explicit pending / analyzing states. The user
        // sees a continuous, honest "still being checked" message
        // until Vision actually decides. This is the only allowed
        // transition into "Validée".
        return _StatusBadge(
          label: 'En vérification…',
          background: Colors.black.withValues(alpha: 0.65),
          icon: Icons.hourglass_top_rounded,
        );
      case PhotoModerationStatus.manualReview:
        // Orange "À vérifier" — distinct from the in-progress dark
        // badge AND from the final approved/rejected verdicts. Tells
        // the user "an admin is reviewing" without using technical
        // wording.
        return const _StatusBadge(
          label: 'À vérifier',
          background: AppColors.warning,
          icon: Icons.support_agent_rounded,
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
