import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_spacing.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../core/utils/extensions.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../../profile_moderation/data/photo_moderation_repository.dart';
import '../../../profile_moderation/domain/photo_moderation_status.dart';
import '../../../profile_setup/data/profile_repository.dart';
import '../../../profile_setup/domain/user_profile.dart';
import '../../../profile_setup/presentation/providers/profile_provider.dart';
import 'providers/profile_photos_provider.dart';
import 'widgets/photo_tile.dart';

/// Lets the user add, replace and delete photos. The grid is capped at
/// [UserProfile.maxPhotos]. Photos remain private — only the post-call
/// reveal screen surfaces them externally.
class EditPhotosScreen extends ConsumerStatefulWidget {
  const EditPhotosScreen({super.key});

  @override
  ConsumerState<EditPhotosScreen> createState() => _EditPhotosScreenState();
}

class _EditPhotosScreenState extends ConsumerState<EditPhotosScreen> {
  final _picker = ImagePicker();
  bool _busy = false;

  Future<Uint8List?> _pickBytes() async {
    try {
      final picked = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1600,
        imageQuality: 88,
      );
      if (picked == null) return null;
      return picked.readAsBytes();
    } catch (e) {
      if (mounted) context.showSnack('$e');
      return null;
    }
  }

  Future<void> _addPhoto(UserProfile profile) async {
    if (profile.photoUrls.length >= UserProfile.maxPhotos) {
      final l10n = AppLocalizations.of(context);
      context.showSnack(l10n.photosMaxReached(UserProfile.maxPhotos));
      return;
    }
    setState(() => _busy = true);
    final bytes = await _pickBytes();
    if (bytes == null) {
      setState(() => _busy = false);
      return;
    }
    final repo = ref.read(profileRepositoryProvider);
    final url = await repo.uploadPhoto(profile.userId, bytes);
    await repo.saveProfile(
      profile.copyWith(photoUrls: [...profile.photoUrls, url]),
    );
    // Fire-and-forget moderation pass. UI surfaces only the verdict
    // — the SnackBar (and the hasApprovedPhoto provider invalidation)
    // happen inside _moderateAndSurface.
    unawaited(_moderateAndSurface(url));
    if (!mounted) return;
    setState(() => _busy = false);
  }

  Future<void> _replacePhoto(UserProfile profile, int index) async {
    setState(() => _busy = true);
    final bytes = await _pickBytes();
    if (bytes == null) {
      setState(() => _busy = false);
      return;
    }
    final repo = ref.read(profileRepositoryProvider);
    final newUrl = await repo.uploadPhoto(profile.userId, bytes);
    final oldUrl = profile.photoUrls[index];
    final next = [...profile.photoUrls];
    next[index] = newUrl;
    await repo.saveProfile(profile.copyWith(photoUrls: next));
    await repo.deletePhoto(oldUrl);
    // Moderation on the new photo — old one was already approved by
    // grandfather (or by a prior moderation pass) and gets deleted
    // server-side. The new photo enters the pipeline.
    unawaited(_moderateAndSurface(newUrl));
    if (!mounted) return;
    setState(() => _busy = false);
  }

  /// Calls the Edge Function `analyze-profile-photo` for the freshly
  /// uploaded [storagePath] and surfaces a neutral SnackBar.
  ///
  /// On `approved`, also invalidates [hasApprovedPhotoProvider] so the
  /// next find-date tap immediately sees the new green light.
  Future<void> _moderateAndSurface(String storagePath) async {
    final moderationRepo = ref.read(photoModerationRepositoryProvider);
    if (moderationRepo == null) return;
    final verdict =
        await moderationRepo.analyzeByStoragePath(storagePath);
    if (!mounted) return;
    context.showSnack(verdict.userMessage);
    if (verdict.status == PhotoModerationStatus.approved) {
      // Bust the cached "do I have an approved photo?" so the find-
      // date gate reads the fresh answer on the very next tap.
      ref.invalidate(hasApprovedPhotoProvider);
    }
    // Re-fetch per-photo statuses so the grid overlay shows the
    // verdict for this tile. Whatever the outcome (approved /
    // rejected / manual_review / server-error keeping it pending),
    // the grid must reflect it immediately — no stale "no overlay"
    // on a photo that just got rejected.
    ref.invalidate(myPhotoStatusesProvider);
  }

  Future<void> _deletePhoto(UserProfile profile, int index) async {
    setState(() => _busy = true);
    final repo = ref.read(profileRepositoryProvider);
    final removedUrl = profile.photoUrls[index];
    // Order is critical here. `UserProfile.photoUrls` is NOT persisted
    // by `saveProfile` — the field is derived at read time from the
    // `user_photos` rows (cf. `SupabaseProfileRepository.getProfile`).
    // The previous order (saveProfile -> deletePhoto) therefore did
    // NOT remove anything from the source of truth on the first call :
    // saveProfile triggered an internal _refresh which re-SELECTed
    // user_photos with the row still present, the StreamProvider
    // re-emitted the same profile, and the grid kept showing the
    // photo. The user had to tap again to trigger a second cycle —
    // by which time deletePhoto from the first tap had finally
    // removed the row, so the second _refresh saw it gone. Hence
    // the "deux clics pour supprimer" bug.
    //
    // Fix : DELETE first (storage + user_photos row), then bust the
    // profile cache so watchProfile re-emits with the row gone in a
    // single user gesture. The saveProfile call is dropped — it was
    // a no-op for photoUrls anyway and re-UPSERTing the profile row
    // on every photo delete was wasteful.
    await repo.deletePhoto(removedUrl);
    // Force a re-emission on `watchProfile` WITHOUT invalidating the
    // StreamProvider — `ref.invalidate(currentProfileProvider)` would
    // push the provider through AsyncLoading, which cascades through
    // `_RouterNotifier.refreshListenable` to `decideRedirect` gate 4
    // (signedIn + profileLoading → /splash) → gate 6 (on splash +
    // complete → /home). That bounced the user out of /profile/photos
    // mid-delete (build 36 bug). Going through the repo refresh
    // keeps the provider in AsyncData so the router never sees a
    // loading flicker — user stays on /profile/photos.
    await repo.refreshProfile(profile.userId);
    if (!mounted) return;
    // Bust the per-tile status cache too so a deleted photo never
    // lingers as a stale "rejected" or "pending" badge for the row
    // that does not exist anymore.
    ref.invalidate(myPhotoStatusesProvider);
    setState(() => _busy = false);
  }

  Future<void> _openMenu(UserProfile profile, int index) async {
    final l10n = AppLocalizations.of(context);
    final action = await showModalBottomSheet<_PhotoAction>(
      context: context,
      backgroundColor: AppColors.surfaceElevated,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.refresh_rounded,
                  color: AppColors.textPrimary),
              title: Text(l10n.photosOptionReplace,
                  style: AppTypography.bodyStrong),
              onTap: () =>
                  Navigator.of(context).pop(_PhotoAction.replace),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline_rounded,
                  color: AppColors.error),
              title: Text(
                l10n.photosOptionDelete,
                style: AppTypography.bodyStrong
                    .copyWith(color: AppColors.error),
              ),
              onTap: () => Navigator.of(context).pop(_PhotoAction.delete),
            ),
            ListTile(
              leading: const Icon(Icons.close_rounded,
                  color: AppColors.textSecondary),
              title: Text(l10n.photosOptionCancel, style: AppTypography.body),
              onTap: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      ),
    );
    if (action == _PhotoAction.replace) {
      await _replacePhoto(profile, index);
    } else if (action == _PhotoAction.delete) {
      await _deletePhoto(profile, index);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final profileAsync = ref.watch(currentProfileProvider);

    return profileAsync.when(
      loading: () => const AppScaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => AppScaffold(body: Center(child: Text('$e'))),
      data: (profile) {
        if (profile == null) return const AppScaffold(body: SizedBox.shrink());

        return AppScaffold(
          appBar: AppBar(
            title: Text(l10n.editPhotosTitle),
            leading: const BackButton(),
          ),
          body: ListView(
            padding: const EdgeInsets.only(top: AppSpacing.sm, bottom: 64),
            children: [
              _PrivacyBanner(l10n: l10n),
              const SizedBox(height: AppSpacing.lg),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(l10n.editPhotosTitle, style: AppTypography.h2),
                  Text(
                    l10n.photosCount(
                      profile.photoUrls.length,
                      UserProfile.maxPhotos,
                    ),
                    style: AppTypography.caption.copyWith(
                      color: AppColors.textTertiary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              _Grid(
                profile: profile,
                busy: _busy,
                onAdd: () => _addPhoto(profile),
                onTapPhoto: (i) => _openMenu(profile, i),
              ),
              if (profile.photoUrls.isEmpty) ...[
                const SizedBox(height: AppSpacing.lg),
                Text(
                  l10n.photosEmptyBody,
                  textAlign: TextAlign.center,
                  style: AppTypography.body.copyWith(
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

enum _PhotoAction { replace, delete }

class _Grid extends ConsumerWidget {
  const _Grid({
    required this.profile,
    required this.busy,
    required this.onAdd,
    required this.onTapPhoto,
  });

  final UserProfile profile;
  final bool busy;
  final VoidCallback onAdd;
  final ValueChanged<int> onTapPhoto;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bytesAsync = ref.watch(profilePhotoBytesProvider);
    // Per-tile moderation status. Empty map on error → tiles fall
    // back to "no overlay" (= behave as approved). Invalidated on
    // upload verdict + delete so the overlay reflects the latest DB
    // state without ever flashing stale badges.
    final statuses = ref.watch(myPhotoStatusesProvider).asData?.value ??
        const <String, PhotoModerationStatus>{};

    final count = profile.photoUrls.length;
    final hasAddSlot = count < UserProfile.maxPhotos;
    final total = count + (hasAddSlot ? 1 : 0);

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: total,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
      ),
      itemBuilder: (context, i) {
        if (i == count) {
          return PhotoTile.add(
            onTap: busy ? () {} : onAdd,
            label: AppLocalizations.of(context).photosAddCta,
          );
        }
        return bytesAsync.when(
          loading: () => const PhotoTile.loading(),
          error: (_, _) => PhotoTile.add(onTap: () => onTapPhoto(i)),
          data: (bytes) {
            final b = i < bytes.length ? bytes[i] : null;
            if (b == null) {
              return PhotoTile.add(onTap: () => onTapPhoto(i));
            }
            return PhotoTile.filled(
              bytes: b,
              onTap: () => onTapPhoto(i),
              status: statuses[profile.photoUrls[i]],
            );
          },
        );
      },
    );
  }
}

class _PrivacyBanner extends StatelessWidget {
  const _PrivacyBanner({required this.l10n});

  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: AppColors.violetSoft,
        borderRadius: AppRadius.brSm,
        border: Border.all(
          color: AppColors.brandViolet.withValues(alpha: 0.4),
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.shield_outlined,
              size: 18, color: AppColors.brandViolet),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              l10n.photosPrivacyHeader,
              style: AppTypography.caption.copyWith(
                color: AppColors.brandViolet,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
