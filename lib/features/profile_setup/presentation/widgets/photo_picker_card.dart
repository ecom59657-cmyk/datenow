import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_spacing.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../core/utils/extensions.dart';
import '../../../../l10n/app_localizations.dart';

/// Tap-target to pick a profile photo. Shows a small thumbnail preview once
/// a picture is chosen — that preview is the **only** place in the app where
/// the user sees their own picture before a successful date.
class PhotoPickerCard extends StatelessWidget {
  const PhotoPickerCard({
    super.key,
    required this.bytes,
    required this.onPicked,
  });

  final Uint8List? bytes;
  final ValueChanged<Uint8List> onPicked;

  Future<void> _pick(BuildContext context) async {
    try {
      final picker = ImagePicker();
      final picked = await picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1200,
        imageQuality: 88,
      );
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      onPicked(bytes);
    } catch (e) {
      if (context.mounted) context.showSnack('$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final has = bytes != null;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _pick(context),
        borderRadius: AppRadius.brLg,
        child: Container(
          padding: const EdgeInsets.all(AppSpacing.md),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: AppRadius.brLg,
            border: Border.all(
              color: has ? AppColors.brandPink : AppColors.hairline,
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
