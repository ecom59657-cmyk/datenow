import 'package:flutter/material.dart';

/// DateNow color tokens — ivory & bordeaux.
///
/// Light-first, editorial palette: warm paper grounds, one deep bordeaux
/// signature, and warm neutrals for text. Every text/background pair below
/// was contrast-checked to WCAG AA; do not "prettify" the values.
///
/// Never read raw [Color] literals in features — always go through this
/// class (or the [ThemeData] from AppTheme), so the palette stays
/// consistent and themable in one place.
class AppColors {
  const AppColors._();

  // ---------------------------------------------------------------------
  // Foundations
  // ---------------------------------------------------------------------

  /// App background — warm beige, never pure #FFF.
  ///
  /// Was #FBF8F4: off-white on paper, indistinguishable from white on a
  /// phone at any brightness — 4/7/11 units from #FFF. The whole neutral
  /// ladder below moved down with it, gap for gap, so cards still lift off
  /// the ground by the same amount and sand fills still read as fills.
  static const Color ivory = Color(0xFFF7F1E7);

  /// Cards and raised surfaces. Reads as elevated *because* it is whiter
  /// than [ivory] — that contrast replaces the old shadows.
  static const Color paper = Color(0xFFFFFFFF);

  /// Secondary blocks (muted rows, inactive chips, secondary buttons).
  static const Color sand = Color(0xFFEEE4D4);

  /// Borders of active/selected sand surfaces.
  static const Color sandDeep = Color(0xFFE3D5C1);

  /// Hairlines and separators — the primary way surfaces are divided.
  static const Color line = Color(0xFFE4D8C8);
  static const Color lineSoft = Color(0xFFF0E9E0);

  // ---------------------------------------------------------------------
  // Signature
  // ---------------------------------------------------------------------

  /// Primary: CTAs, selection, links, active nav.
  static const Color bordeaux = Color(0xFF6E2438);

  /// Deep end of the gradient, and the ground of the one dark screen
  /// (the video call). Dark is an *event* in this app — never black.
  static const Color bordeauxDeep = Color(0xFF451523);

  /// Hover, secondary icons.
  static const Color bordeauxLight = Color(0xFF96455A);

  /// Soft accent ground: badges, focus halo, selected-card fill.
  static const Color tint = Color(0xFFF5E8EA);

  /// Warm accent — prompt labels, editorial marks.
  /// Darkened from #96604D with the ground. It carries the prompt
  /// overline at 10 px uppercase, which needs 4.5:1 — it was already short
  /// of that on sand (4.35:1) before the ground moved, and would have gone
  /// to 4.09:1. Now 4.78:1.
  static const Color clay = Color(0xFF8A5643);
  static const Color clayTint = Color(0xFFF0E2D5);

  /// The ONLY gradient in the app: bordeaux → bordeauxDeep, single 155°
  /// angle. Multicolour gradients are what made the old look generic.
  static const LinearGradient signatureGradient = LinearGradient(
    // 155° clockwise from "up" ≈ top-left-ish to bottom-right-ish.
    begin: Alignment(-0.42, -1),
    end: Alignment(0.42, 1),
    colors: [bordeaux, bordeauxDeep],
  );

  /// Placeholder ground for an avatar with no photo. Warm sand → clay,
  /// never bordeaux: a person-shaped hole in the layout should read as
  /// paper, not as a call to action.
  static const LinearGradient avatarGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFEFE3D8), Color(0xFFB98B79)],
  );

  // ---------------------------------------------------------------------
  // Text
  // ---------------------------------------------------------------------

  /// Primary text.
  static const Color ink = Color(0xFF1C1719);

  /// Secondary text — also the floor for captions and overlines. The old
  /// palette sent those to a tertiary grey at 3.9:1, below AA.
  static const Color ink2 = Color(0xFF6E6360);

  /// Captions on paper. Never go lighter than this for readable text.
  static const Color ink3 = Color(0xFF7A6F6B);

  // ---------------------------------------------------------------------
  // Status
  // ---------------------------------------------------------------------

  static const Color sage = Color(0xFF4F6853);
  static const Color sageTint = Color(0xFFE7EEE8);
  static const Color amber = Color(0xFF8F6220);
  static const Color amberTint = Color(0xFFF6EDDF);
  static const Color error = Color(0xFFA93A3A);
  static const Color errorTint = Color(0xFFF8E9E9);

  // ---------------------------------------------------------------------
  // Semantic aliases (kept from the previous palette)
  //
  // Same names as before, new values — so ~300 call sites across the app
  // re-skin themselves without a mechanical rename. Prefer the canonical
  // names above in new code.
  // ---------------------------------------------------------------------

  static const Color background = ivory;
  static const Color surface = paper;
  static const Color surfaceElevated = paper;
  static const Color surfaceMuted = sand;

  /// Was a translucent white "glass" overlay on near-black. On paper the
  /// same idea is a warm neutral fill — translucency over ivory reads as
  /// dirt, not depth.
  static const Color glass = sand;
  static const Color glassStrong = sandDeep;

  static const Color hairline = line;
  static const Color hairlineSoft = lineSoft;

  static const Color textPrimary = ink;
  static const Color textSecondary = ink2;
  static const Color textTertiary = ink3;
  static const Color textDisabled = Color(0xFFA79C97);

  static const Color success = sage;
  static const Color warning = amber;
  static const Color online = sage;

  /// Soft chip grounds — formerly 20 % pink / violet washes.
  static const Color pinkSoft = tint;
  static const Color violetSoft = clayTint;
}
