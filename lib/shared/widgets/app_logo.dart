import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_typography.dart';

/// The DateNow wordmark — `Date` in white, `Now` painted with the brand
/// gradient. Composable into any layout (splash, auth, headers).
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
                  color: AppColors.textPrimary,
                ),
              ),
              WidgetSpan(
                alignment: PlaceholderAlignment.baseline,
                baseline: TextBaseline.alphabetic,
                child: ShaderMask(
                  shaderCallback: (rect) =>
                      AppColors.brandGradient.createShader(rect),
                  child: Text(
                    'Now',
                    style: AppTypography.display.copyWith(
                      fontSize: fontSize,
                      color: Colors.white,
                    ),
                  ),
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
/// (assets/logo/datenow_logo.png), rounded and given a soft brand glow.
/// Using the real icon keeps the in-app logo, splash and App Icon identical.
class _LogoMark extends StatelessWidget {
  const _LogoMark({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(size * 0.24);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: [
          BoxShadow(
            color: AppColors.brandPink.withValues(alpha: 0.3),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
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
