import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import 'gradient_background.dart';

/// Standard scaffold used by every screen in DateNow. Wraps content with the
/// gradient background, applies safe-area padding, and configures status-bar
/// styling so screens never have to repeat this scaffolding.
class AppScaffold extends StatelessWidget {
  const AppScaffold({
    super.key,
    required this.body,
    this.appBar,
    this.bottomBar,
    this.floatingActionButton,
    this.floatingActionButtonLocation,
    this.padding = AppSpacing.pagePadding,
    this.applyHorizontalPadding = true,
    this.resizeToAvoidBottomInset = true,
    this.glowIntensity = 1.0,
  });

  final Widget body;
  final PreferredSizeWidget? appBar;
  final Widget? bottomBar;
  final Widget? floatingActionButton;
  final FloatingActionButtonLocation? floatingActionButtonLocation;
  final EdgeInsets padding;
  final bool applyHorizontalPadding;
  final bool resizeToAvoidBottomInset;
  final double glowIntensity;

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      // Dark glyphs over the ivory ground. Screens that paint their own
      // dark surface — only the call — override this locally.
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark,
        statusBarBrightness: Brightness.light,
        systemNavigationBarColor: AppColors.ivory,
        systemNavigationBarIconBrightness: Brightness.dark,
      ),
      child: Scaffold(
        backgroundColor: AppColors.ivory,
        extendBodyBehindAppBar: true,
        extendBody: true,
        resizeToAvoidBottomInset: resizeToAvoidBottomInset,
        appBar: appBar,
        bottomNavigationBar: bottomBar,
        floatingActionButton: floatingActionButton,
        floatingActionButtonLocation: floatingActionButtonLocation,
        body: GradientBackground(
          intensity: glowIntensity,
          child: SafeArea(
            bottom: bottomBar == null,
            child: Padding(
              padding: applyHorizontalPadding ? padding : EdgeInsets.zero,
              child: body,
            ),
          ),
        ),
      ),
    );
  }
}
