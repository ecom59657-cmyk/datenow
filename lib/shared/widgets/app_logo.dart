import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_typography.dart';

/// The DateNow wordmark — `Date` in ink, `Now` in bordeaux, both set in
/// Newsreader 400. The wordmark is what carries the elegance now, so it is
/// flat colour: a gradient-filled logo is the single most generic thing a
/// dating app can put on its splash screen.
class AppLogo extends StatelessWidget {
  const AppLogo({
    super.key,
    this.fontSize = 40,
    this.iconSize,
  });

  final double fontSize;
  final double? iconSize;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _LogoMark(size: iconSize ?? fontSize * 1.05),
        const SizedBox(width: 12),
        Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: 'Date',
                style: AppTypography.display.copyWith(
                  fontSize: fontSize,
                  fontWeight: FontWeight.w400,
                  color: AppColors.ink,
                ),
              ),
              TextSpan(
                text: 'Now',
                style: AppTypography.display.copyWith(
                  fontSize: fontSize,
                  fontWeight: FontWeight.w400,
                  color: AppColors.bordeaux,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The DateNow mark — the official app-icon artwork itself
/// (assets/logo/datenow_logo.png), rounded. No glow: on ivory it read as a
/// smudge under the icon.
class _LogoMark extends StatelessWidget {
  const _LogoMark({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(size * 0.24);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(borderRadius: radius),
      child: ClipRRect(
        borderRadius: radius,
        child: Image.asset(
          'assets/logo/datenow_logo.png',
          width: size,
          height: size,
          fit: BoxFit.cover,
          filterQuality: FilterQuality.medium,
        ),
      ),
    );
  }
}
