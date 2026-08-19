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
  const AppLogo({super.key, this.fontSize = 40});

  final double fontSize;

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: 'Date',
            style: AppTypography.display.copyWith(
              fontSize: fontSize,
              fontWeight: FontWeight.w400,
              color: AppColors.ink,
            ),
          ),
          TextSpan(
            text: 'Now',
            style: AppTypography.display.copyWith(
              fontSize: fontSize,
              fontWeight: FontWeight.w400,
              color: AppColors.bordeaux,
            ),
          ),
        ],
      ),
    );
  }
}
