import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';

enum AppButtonVariant { primary, secondary, ghost }

enum AppButtonSize { regular, large }

/// The single button used across DateNow. Three variants, two sizes and a
/// loading state that keeps its label.
///
/// One rule governs its use: **a screen carries at most one filled bordeaux
/// button.** Two filled CTAs side by side cancel each other's hierarchy —
/// the second one becomes [AppButtonVariant.secondary].
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
      // A disabled primary used to be white text over bordeaux at 50 %
      // opacity — pale pink under white, which fails contrast and reads
      // as "loading" rather than "not yet available". It then became sand
      // on ivory with an ink3 label, which was legible but so quiet that
      // people stopped seeing a button at all: it now keeps a border and
      // a darker label so the shape still reads as an action.
      color: switch (variant) {
        AppButtonVariant.primary =>
          _enabled ? Colors.white : AppColors.ink2,
        AppButtonVariant.secondary => AppColors.ink,
        AppButtonVariant.ghost => AppColors.bordeaux,
      },
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

    final sized = expanded ? SizedBox(width: double.infinity, child: body) : body;

    // The button is an InkWell over a Container, so VoiceOver has nothing
    // to announce on its own. Declaring it here also lets a disabled or
    // loading button be read as unavailable instead of silently inert.
    return Semantics(
      button: true,
      enabled: _enabled,
      label: label,
      child: ExcludeSemantics(child: sized),
    );
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
    return DecoratedBox(
        decoration: BoxDecoration(
          // Flat bordeaux, not the signature gradient: the gradient is for
          // large surfaces (hero cards, the call ground), and a shadow
          // under every CTA is what made the old look heavy. Disabled is
          // a sand fill, not a faded bordeaux.
          color: enabled ? AppColors.bordeaux : AppColors.sand,
          borderRadius: AppRadius.brPill,
          border: enabled
              ? null
              : const Border.fromBorderSide(
                  BorderSide(color: AppColors.sandDeep),
                ),
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: AppRadius.brPill,
          child: InkWell(
            onTap: onPressed,
            borderRadius: AppRadius.brPill,
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
        color: AppColors.sand,
        borderRadius: AppRadius.brPill,
        child: InkWell(
          onTap: onPressed,
          borderRadius: AppRadius.brPill,
          child: Container(
            height: height,
            padding: padding,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: AppRadius.brPill,
              border: Border.all(color: AppColors.sandDeep),
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
        borderRadius: AppRadius.brPill,
        child: InkWell(
          onTap: onPressed,
          borderRadius: AppRadius.brPill,
          child: Container(
            height: height,
            padding: padding,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: AppRadius.brPill,
              border: Border.all(color: AppColors.line),
            ),
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
    // Loading keeps the label: a button that empties itself into a spinner
    // leaves the user unsure of what they just triggered, and the width
    // jump is visible on every submit.
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.max,
      children: [
        if (isLoading) ...[
          SizedBox(
            height: 18,
            width: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation(color),
            ),
          ),
          const SizedBox(width: 8),
        ] else if (icon != null) ...[
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
