import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';

/// The base surface for elevated content: white paper on the ivory ground,
/// separated by a 1 px hairline rather than a shadow.
///
/// This replaces the old dark "glass" card (translucent white over
/// near-black, with a backdrop blur). Blur over a light ground only muddies
/// what is behind it, and it cost a saveLayer on every card in a list.
class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppSpacing.lg),
    this.borderRadius = AppRadius.brLg,
    this.borderColor = AppColors.line,
    this.color,
    this.onTap,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final BorderRadius borderRadius;
  final Color borderColor;
  final Color? color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final decorated = Container(
      // Clip so a full-bleed child — a Veil header, a photo — follows the
      // card's corners instead of squaring them off.
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: color ?? AppColors.paper,
        borderRadius: borderRadius,
        border: Border.all(color: borderColor, width: 1),
      ),
      padding: padding,
      child: child,
    );

    if (onTap == null) return decorated;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: borderRadius,
        // Warm, barely-there press feedback — the default ink splash is a
        // cold grey that fights the palette.
        splashColor: AppColors.tint,
        highlightColor: AppColors.tint.withValues(alpha: 0.5),
        child: decorated,
      ),
    );
  }
}

/// Former name of [AppCard]. Kept so the 21 existing call sites keep
/// compiling; they migrate as their screens are reworked.
@Deprecated('Utiliser AppCard')
class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppSpacing.lg),
    this.borderRadius = AppRadius.brLg,
    this.borderColor = AppColors.line,
    this.color,
    this.blur = 0,
    this.onTap,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final BorderRadius borderRadius;
  final Color borderColor;
  final Color? color;

  /// Ignored — kept only so old call sites still analyse.
  final double blur;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => AppCard(
        padding: padding,
        borderRadius: borderRadius,
        borderColor: borderColor,
        color: color,
        onTap: onTap,
        child: child,
      );
}
