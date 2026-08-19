import 'package:flutter/material.dart';

import '../../../../shared/widgets/veil.dart';

/// Stand-in shown anywhere a photo would normally appear **before** a
/// successful live date. Real photos only ever surface on the post-call
/// reveal screen.
///
/// This is now the [Veil] at [VeilLevel.v4] over a warm placeholder, so the
/// pre-match silhouette, the suggestion cards and the reveal are visibly
/// the same object at different distances — instead of three unrelated
/// widgets that each invented their own grey circle.
class BlurredAvatar extends StatelessWidget {
  const BlurredAvatar({super.key, this.size = 120, this.level = VeilLevel.v4});

  final double size;

  /// Lets a caller show a closer level (e.g. [VeilLevel.v3] once matched).
  final VeilLevel level;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Veil(
        level: level,
        child: const VeilPlaceholder(),
      ),
    );
  }
}
