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

class _LogoMark extends StatelessWidget {
  const _LogoMark({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: AppColors.brandGradient,
        borderRadius: BorderRadius.circular(size * 0.28),
        boxShadow: [
          BoxShadow(
            color: AppColors.brandPink.withValues(alpha: 0.4),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Icon(
        Icons.favorite_rounded,
        color: Colors.white,
        size: size * 0.5,
      ),
    );
  }
}
