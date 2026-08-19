import 'package:flutter/material.dart';

import '../../../../app/theme/app_colors.dart';

/// Premium silhouette stand-in shown anywhere a photo would normally appear
/// **before** a successful live date. Real photos are intentionally locked
/// behind the post-call reveal screen.
class BlurredAvatar extends StatelessWidget {
  const BlurredAvatar({super.key, this.size = 120});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppColors.surfaceElevated,
            AppColors.surface,
          ],
        ),
        border: Border.all(color: AppColors.hairline, width: 1.5),
        boxShadow: [
          BoxShadow(
            color: AppColors.bordeaux.withValues(alpha: 0.15),
            blurRadius: 28,
            spreadRadius: 2,
          ),
        ],
      ),
      child: Center(
        child: Icon(
          Icons.person_rounded,
          color: AppColors.textTertiary.withValues(alpha: 0.7),
          size: size * 0.45,
        ),
      ),
    );
  }
}
