import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_typography.dart';

/// The DateNow wordmark — `Date` in ink, `Now` in bordeaux, set in
/// Newsreader 400.
///
/// The wordmark stands alone: the app-icon tile that used to sit next to it
/// duplicated the name it was already spelling out, and on the ivory ground
/// its own near-white background read as a pale square rather than a mark.
/// The icon still exists as `assets/logo/datenow_logo.png` — it is the
/// master flutter_launcher_icons builds the iOS and Android sets from.
class AppLogo extends StatelessWidget {
  const AppLogo({
    super.key,
    this.fontSize = 40,
    this.showMark = false,
    this.onDark = false,
  });

  final double fontSize;

  /// Inverts the wordmark for a bordeaux ground. "Now" in bordeaux would
  /// disappear into it, so both words go to paper and the second one keeps
  /// the pairing by sitting slightly back.
  final bool onDark;

  /// Shows the app icon beside the wordmark. Off by default: on the auth
  /// screen the mark only repeated the name it sits next to. The splash
  /// turns it on, because there the icon IS the app arriving.
  final bool showMark;

  @override
  Widget build(BuildContext context) {
    final wordmark = Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: 'Date',
            style: AppTypography.display.copyWith(
              fontSize: fontSize,
              fontWeight: FontWeight.w400,
              color: onDark ? AppColors.paper : AppColors.ink,
            ),
          ),
          TextSpan(
            text: 'Now',
            style: AppTypography.display.copyWith(
              fontSize: fontSize,
              fontWeight: FontWeight.w400,
              // On bordeaux, "Now" in bordeaux disappears into the ground.
              // Both words go to paper and the second sits slightly back,
              // which keeps the two-part rhythm without a second hue.
              color: onDark
                  ? AppColors.paper.withValues(alpha: 0.72)
                  : AppColors.bordeaux,
            ),
          ),
        ],
      ),
    );

    if (!showMark) return wordmark;
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _LogoMark(size: fontSize * 1.05, onDark: onDark),
        SizedBox(width: fontSize * 0.28),
        wordmark,
      ],
    );
  }
}

/// The app icon itself (`assets/logo/datenow_logo.png`), so the splash and
/// the home-screen icon are the same object.
///
/// It carries a hairline: the artwork has an ivory ground and so does the
/// splash, so without one the tile dissolves into the screen — which is
/// what got it removed from the wordmark in the first place.
class _LogoMark extends StatelessWidget {
  const _LogoMark({required this.size, this.onDark = false});

  final double size;
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(size * 0.24);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: radius,
        // On the bordeaux splash the ivory tile stands on its own; the
        // hairline is only there to keep it from dissolving into an ivory
        // ground.
        border: onDark ? null : Border.all(color: AppColors.line),
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: Image.asset(
          'assets/logo/datenow_logo.png',
          width: size,
          height: size,
          fit: BoxFit.cover,
          filterQuality: FilterQuality.medium,
        ),
      ),
    );
  }
}
