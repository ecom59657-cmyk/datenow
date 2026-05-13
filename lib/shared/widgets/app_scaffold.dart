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
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
        systemNavigationBarColor: AppColors.background,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
      child: Scaffold(
        backgroundColor: AppColors.background,
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
