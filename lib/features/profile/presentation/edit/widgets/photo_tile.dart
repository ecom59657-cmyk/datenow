import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../../../app/theme/app_colors.dart';
import '../../../../../app/theme/app_spacing.dart';
import '../../../../../app/theme/app_typography.dart';

/// One slot in the [PhotoGrid]: either the user's photo thumbnail (with a
/// menu trigger) or an empty "add" placeholder.
class PhotoTile extends StatelessWidget {
  const PhotoTile.add({super.key, required this.onTap, this.label})
      : bytes = null,
        loading = false;

  const PhotoTile.filled({
    super.key,
    required Uint8List this.bytes,
    required this.onTap,
  })  : label = null,
        loading = false;

  const PhotoTile.loading({super.key})
      : bytes = null,
        onTap = null,
        label = null,
        loading = true;

  final Uint8List? bytes;
  final VoidCallback? onTap;
  final String? label;
  final bool loading;

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
              Image.memory(bytes!, fit: BoxFit.cover),
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
            ],
          ),
        ),
      ),
    );
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
