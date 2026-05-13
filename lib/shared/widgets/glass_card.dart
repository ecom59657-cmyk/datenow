import 'dart:ui';

import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';

/// A translucent card with a subtle backdrop blur. Use this as the base
/// surface for elevated content on top of [GradientBackground].
class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppSpacing.lg),
    this.borderRadius = AppRadius.brLg,
    this.borderColor = AppColors.hairline,
    this.color,
    this.blur = 18,
    this.onTap,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final BorderRadius borderRadius;
  final Color borderColor;
  final Color? color;
  final double blur;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final inner = ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: Container(
          decoration: BoxDecoration(
            color: color ?? AppColors.glass,
            borderRadius: borderRadius,
            border: Border.all(color: borderColor, width: 1),
          ),
          padding: padding,
          child: child,
        ),
      ),
    );

    if (onTap == null) return inner;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: borderRadius,
        child: inner,
      ),
    );
  }
}
