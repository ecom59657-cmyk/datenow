import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';

/// Small brand-colored spinner — used while resolving async providers.
class LoadingIndicator extends StatelessWidget {
  const LoadingIndicator({super.key, this.size = 24, this.strokeWidth = 2.5});

  final double size;
  final double strokeWidth;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SizedBox(
        height: size,
        width: size,
        child: CircularProgressIndicator(
          strokeWidth: strokeWidth,
          valueColor: const AlwaysStoppedAnimation(AppColors.bordeaux),
        ),
      ),
    );
  }
}
