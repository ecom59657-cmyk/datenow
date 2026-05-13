import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'app_colors.dart';

/// Centralised typography for DateNow.
///
/// We use Plus Jakarta Sans as our display/system font — it has the geometric
/// modernity of SF Pro Display while being free via Google Fonts.
class AppTypography {
  const AppTypography._();

  static TextStyle _base({
    required double size,
    required FontWeight weight,
    double? height,
    double? letterSpacing,
    Color color = AppColors.textPrimary,
  }) {
    return GoogleFonts.plusJakartaSans(
      fontSize: size,
      fontWeight: weight,
      height: height,
      letterSpacing: letterSpacing,
      color: color,
    );
  }

  // Display — used for splash & hero headlines.
  static TextStyle get display => _base(
        size: 40,
        weight: FontWeight.w700,
        height: 1.05,
        letterSpacing: -0.5,
      );

  // Headlines.
  static TextStyle get h1 => _base(
        size: 32,
        weight: FontWeight.w700,
        height: 1.15,
        letterSpacing: -0.4,
      );

  static TextStyle get h2 => _base(
        size: 26,
        weight: FontWeight.w600,
        height: 1.2,
        letterSpacing: -0.3,
      );

  static TextStyle get h3 => _base(
        size: 20,
        weight: FontWeight.w600,
        height: 1.25,
      );

  // Body.
  static TextStyle get bodyLarge => _base(
        size: 17,
        weight: FontWeight.w400,
        height: 1.45,
        color: AppColors.textPrimary,
      );

  static TextStyle get body => _base(
        size: 15,
        weight: FontWeight.w400,
        height: 1.45,
        color: AppColors.textSecondary,
      );

  static TextStyle get bodyStrong => _base(
        size: 15,
        weight: FontWeight.w600,
        height: 1.4,
      );

  // Labels / buttons / captions.
  static TextStyle get button => _base(
        size: 16,
        weight: FontWeight.w600,
        letterSpacing: 0.1,
      );

  static TextStyle get caption => _base(
        size: 12,
        weight: FontWeight.w500,
        height: 1.3,
        color: AppColors.textTertiary,
        letterSpacing: 0.2,
      );

  static TextStyle get overline => _base(
        size: 11,
        weight: FontWeight.w600,
        color: AppColors.textTertiary,
        letterSpacing: 1.4,
      );

  /// Builds a Material [TextTheme] mapped from our tokens.
  static TextTheme textTheme() {
    return TextTheme(
      displayLarge: display,
      displayMedium: h1,
      displaySmall: h2,
      headlineMedium: h2,
      headlineSmall: h3,
      titleLarge: h3,
      titleMedium: bodyStrong,
      bodyLarge: bodyLarge,
      bodyMedium: body,
      bodySmall: caption,
      labelLarge: button,
      labelSmall: overline,
    );
  }
}
