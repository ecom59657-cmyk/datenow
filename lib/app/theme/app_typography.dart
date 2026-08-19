import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'app_colors.dart';

/// Centralised typography for DateNow — two families, one job each.
///
/// * **Newsreader** (serif, 300/400) carries display, headlines, first
///   names and standout figures. Its light weights and tight tracking are
///   what make the app read editorial rather than generic-app. It is
///   **never set in capitals** — small caps in a serif this light look
///   broken, and it is the fastest way to lose the premium feel.
/// * **Plus Jakarta Sans** (400–700) carries everything functional: body,
///   buttons, labels, captions, overlines.
class AppTypography {
  const AppTypography._();

  /// Serif display face. [letterSpacing] is expressed in logical pixels,
  /// so callers pass `size * ratio` for the −1.5 %…−3.5 % tracking range.
  static TextStyle _serif({
    required double size,
    required FontWeight weight,
    double? height,
    double? letterSpacing,
    Color color = AppColors.ink,
  }) {
    return GoogleFonts.newsreader(
      fontSize: size,
      fontWeight: weight,
      height: height,
      letterSpacing: letterSpacing,
      color: color,
    );
  }

  static TextStyle _base({
    required double size,
    required FontWeight weight,
    double? height,
    double? letterSpacing,
    Color color = AppColors.ink,
  }) {
    return GoogleFonts.plusJakartaSans(
      fontSize: size,
      fontWeight: weight,
      height: height,
      letterSpacing: letterSpacing,
      color: color,
    );
  }

  // Display & headlines — Newsreader, light weights, tight leading.

  static TextStyle get display => _serif(
        size: 40,
        weight: FontWeight.w300,
        height: 1.0,
        letterSpacing: -1.2, // −3 %
      );

  static TextStyle get h1 => _serif(
        size: 32,
        weight: FontWeight.w300,
        height: 1.06,
        letterSpacing: -0.8, // −2.5 %
      );

  static TextStyle get h2 => _serif(
        size: 26,
        weight: FontWeight.w300,
        height: 1.12,
        letterSpacing: -0.52, // −2 %
      );

  static TextStyle get h3 => _serif(
        size: 20,
        weight: FontWeight.w400,
        height: 1.15,
        letterSpacing: -0.3, // −1.5 %
      );

  // Body & UI — Plus Jakarta Sans.

  static TextStyle get bodyLarge => _base(
        size: 17,
        weight: FontWeight.w400,
        height: 1.5,
      );

  static TextStyle get body => _base(
        size: 15,
        weight: FontWeight.w400,
        height: 1.5,
        color: AppColors.ink2,
      );

  static TextStyle get bodyStrong => _base(
        size: 15,
        weight: FontWeight.w600,
        height: 1.4,
      );

  static TextStyle get button => _base(
        size: 15,
        weight: FontWeight.w600,
        letterSpacing: 0,
      );

  /// Captions sit on [AppColors.ink2], not the tertiary grey: the old
  /// pairing measured 3.9:1, under the 4.5:1 AA floor for small text.
  static TextStyle get caption => _base(
        size: 12,
        weight: FontWeight.w500,
        height: 1.35,
        color: AppColors.ink2,
      );

  /// The one place capitals are allowed — and only in the sans face.
  /// 11 px was too small once tracked out to 0.16 em; it is 12 px now.
  static TextStyle get overline => _base(
        size: 12,
        weight: FontWeight.w700,
        color: AppColors.bordeaux,
        letterSpacing: 1.92, // 0.16 em
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
