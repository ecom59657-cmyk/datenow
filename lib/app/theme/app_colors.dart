import 'package:flutter/material.dart';

/// DateNow color tokens. Dark-first premium palette inspired by Raya / Apple.
///
/// Never read raw [Color] literals in features — always go through this class
/// (or the [ThemeData] from [AppTheme]). That way the palette stays consistent
/// and themable in one place.
class AppColors {
  const AppColors._();

  // Brand gradient — DateNow signature (rose → violet luxe).
  static const Color brandPink = Color(0xFFFF3D7F);
  static const Color brandViolet = Color(0xFFB936FF);
  static const Color brandBlue = Color(0xFF6E7BFF);

  static const LinearGradient brandGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [brandPink, brandViolet],
  );

  static const LinearGradient brandGradientWide = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [brandPink, brandViolet, brandBlue],
  );

  // Backgrounds — deep, layered.
  static const Color background = Color(0xFF0A0A0F);
  static const Color surface = Color(0xFF14141C);
  static const Color surfaceElevated = Color(0xFF1C1C26);
  static const Color surfaceMuted = Color(0xFF0F0F16);

  // Glass / translucent overlays.
  static const Color glass = Color(0x14FFFFFF); // 8% white
  static const Color glassStrong = Color(0x1FFFFFFF); // 12% white
  static const Color hairline = Color(0x1FFFFFFF); // borders
  static const Color hairlineSoft = Color(0x14FFFFFF);

  // Text.
  static const Color textPrimary = Color(0xFFF5F5F7);
  static const Color textSecondary = Color(0xFFB8B8C2);
  static const Color textTertiary = Color(0xFF7A7A85);
  static const Color textDisabled = Color(0xFF4E4E59);

  // Status.
  static const Color success = Color(0xFF34D399);
  static const Color warning = Color(0xFFF59E0B);
  static const Color error = Color(0xFFFF4D6D);
  static const Color online = Color(0xFF34D399);

  // Accent shades used for chips / subtle highlights.
  static const Color pinkSoft = Color(0x33FF3D7F);
  static const Color violetSoft = Color(0x33B936FF);
}
