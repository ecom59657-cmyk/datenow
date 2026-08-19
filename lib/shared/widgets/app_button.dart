import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';

enum AppButtonVariant { primary, secondary, ghost }

enum AppButtonSize { regular, large }

/// The single button used across DateNow. Three variants, two sizes, a
/// built-in loading state, and a gradient primary that matches the brand.
class AppButton extends StatelessWidget {
  const AppButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.variant = AppButtonVariant.primary,
    this.size = AppButtonSize.regular,
    this.icon,
    this.isLoading = false,
    this.expanded = true,
  });

  final String label;
  final VoidCallback? onPressed;
  final AppButtonVariant variant;
  final AppButtonSize size;
  final IconData? icon;
  final bool isLoading;
  final bool expanded;

  bool get _enabled => onPressed != null && !isLoading;

  // Horizontal-only padding. Vertical centering is handled by the inner
  // Container's `alignment: center`, so adding vertical padding here only
  // ate into the content area and clipped the text on some devices.
  EdgeInsets get _padding => const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
      );

  // Comfortable tap targets that always fit the 16 pt button text plus its
  // line-height with margin to spare on every iPhone.
  double get _height => size == AppButtonSize.large ? 56 : 50;

  @override
  Widget build(BuildContext context) {
    final child = _ButtonContent(
      label: label,
      icon: icon,
      isLoading: isLoading,
      color: variant == AppButtonVariant.primary
          ? Colors.white
          : AppColors.textPrimary,
    );

    final Widget body = switch (variant) {
      AppButtonVariant.primary => _PrimaryButton(
          enabled: _enabled,
          onPressed: _enabled ? onPressed : null,
          padding: _padding,
          height: _height,
          child: child,
        ),
      AppButtonVariant.secondary => _SecondaryButton(
          enabled: _enabled,
          onPressed: _enabled ? onPressed : null,
          padding: _padding,
          height: _height,
          child: child,
        ),
      AppButtonVariant.ghost => _GhostButton(
          enabled: _enabled,
          onPressed: _enabled ? onPressed : null,
          padding: _padding,
          height: _height,
          child: child,
        ),
    };

    return expanded ? SizedBox(width: double.infinity, child: body) : body;
  }
}

class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({
    required this.enabled,
    required this.onPressed,
    required this.padding,
    required this.height,
    required this.child,
  });

  final bool enabled;
  final VoidCallback? onPressed;
  final EdgeInsets padding;
  final double height;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: AppColors.signatureGradient,
          borderRadius: AppRadius.brXl,
          boxShadow: enabled
              ? [
                  BoxShadow(
                    color: AppColors.bordeaux.withValues(alpha: 0.35),
                    blurRadius: 24,
                    offset: const Offset(0, 8),
                  ),
                ]
              : null,
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: AppRadius.brXl,
          child: InkWell(
            onTap: onPressed,
            borderRadius: AppRadius.brXl,
            child: Container(
              height: height,
              padding: padding,
              alignment: Alignment.center,
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

class _SecondaryButton extends StatelessWidget {
  const _SecondaryButton({
    required this.enabled,
    required this.onPressed,
    required this.padding,
    required this.height,
    required this.child,
  });

  final bool enabled;
  final VoidCallback? onPressed;
  final EdgeInsets padding;
  final double height;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: Material(
        color: AppColors.surface,
        borderRadius: AppRadius.brXl,
        child: InkWell(
          onTap: onPressed,
          borderRadius: AppRadius.brXl,
          child: Container(
            height: height,
            padding: padding,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: AppRadius.brXl,
              border: Border.all(color: AppColors.hairline),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

class _GhostButton extends StatelessWidget {
  const _GhostButton({
    required this.enabled,
    required this.onPressed,
    required this.padding,
    required this.height,
    required this.child,
  });

  final bool enabled;
  final VoidCallback? onPressed;
  final EdgeInsets padding;
  final double height;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: AppRadius.brXl,
          child: Container(
            height: height,
            padding: padding,
            alignment: Alignment.center,
            child: child,
          ),
        ),
      ),
    );
  }
}

class _ButtonContent extends StatelessWidget {
  const _ButtonContent({
    required this.label,
    required this.icon,
    required this.isLoading,
    required this.color,
  });

  final String label;
  final IconData? icon;
  final bool isLoading;
  final Color color;

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return SizedBox(
        height: 20,
        width: 20,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          valueColor: AlwaysStoppedAnimation(color),
        ),
      );
    }
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.max,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
        ],
        // Flexible + ellipsis prevents long translations from clipping or
        // overflowing horizontally. Explicit text `height` keeps the
        // line-box from creeping above the button height on devices where
        // the default font metrics are slightly taller.
        Flexible(
          child: Text(
            label,
            style: AppTypography.button.copyWith(
              color: color,
              height: 1.15,
            ),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            softWrap: false,
          ),
        ),
      ],
    );
  }
}
