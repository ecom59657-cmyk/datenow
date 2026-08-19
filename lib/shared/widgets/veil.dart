import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import 'grain_overlay.dart';

/// How much of the person is still hidden. Only the blur sigma changes
/// between levels — the warm veil, the grain and the shape stay put, which
/// is what makes the reveal read as one continuous object rather than four
/// different widgets.
enum VeilLevel {
  /// Discover, suggestion cards — a presence, not a face.
  v4(26),

  /// Match found, before the call.
  v3(16),

  /// End of the video date.
  v2(7),

  /// After a mutual decision. The blur is gone and the warm veil drops to
  /// 35 % — but the grain stays, so the photo still belongs to the app.
  v1(0);

  const VeilLevel(this.sigma);

  final double sigma;
}

enum VeilShape {
  /// A person.
  circle,

  /// A card (suggestion, reveal).
  card,
}

/// Timings of the reveal. They are deliberate, and they are the product:
/// the 400 ms of stillness after the tap is what makes the reveal feel
/// like something happening *to* you rather than a state change.
class VeilTiming {
  const VeilTiming._();

  /// Tap → nothing moves. Do not shorten.
  static const Duration stillness = Duration(milliseconds: 400);

  /// Blur travelling from v2 to v1.
  static const Duration reveal = Duration(milliseconds: 1000);

  /// End of the blur travel (stillness + reveal).
  static const Duration settle = Duration(milliseconds: 1400);

  /// When the decision buttons may appear — never before, or the user is
  /// asked to choose about a face they have not finished seeing.
  static const Duration decisionUnlock = Duration(milliseconds: 1600);

  static const Curve curve = Curves.easeOutExpo;
}

/// The Veil — the brand asset of the app.
///
/// Four layers over a photo: a gaussian blur (the only animated one), a
/// warm radial veil in multiply, a constant 3 % grain, and a shape.
class Veil extends StatelessWidget {
  const Veil({
    super.key,
    required this.child,
    this.level = VeilLevel.v4,
    this.shape = VeilShape.circle,
    this.duration = VeilTiming.reveal,
    this.curve = VeilTiming.curve,
    this.scale = 1.0,
  });

  final Widget child;
  final VeilLevel level;
  final VeilShape shape;

  /// Duration of the sigma travel when [level] changes.
  final Duration duration;
  final Curve curve;

  /// Applied to the whole stack — used by the reveal, which scales
  /// 0.94 → 1 while the blur lifts.
  final double scale;

  static const BorderRadius _cardRadius =
      BorderRadius.all(Radius.circular(22));

  @override
  Widget build(BuildContext context) {
    final Widget veiled = TweenAnimationBuilder<double>(
      tween: Tween<double>(end: level.sigma),
      duration: duration,
      curve: curve,
      builder: (context, sigma, child) => _blur(sigma, child!),
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          child,
          // Warm veil. Multiply keeps the photo's own luminance and only
          // pulls it towards the palette — an opacity overlay would wash
          // it grey instead.
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedOpacity(
                duration: duration,
                curve: curve,
                opacity: level == VeilLevel.v1 ? 0.35 : 1,
                child: const DecoratedBox(
                  decoration: BoxDecoration(
                    backgroundBlendMode: BlendMode.multiply,
                    gradient: RadialGradient(
                      radius: 0.95,
                      colors: [
                        Color(0xFFFFF3EA),
                        Color(0xFFD9BCAE),
                        Color(0xFFB98B79),
                      ],
                      stops: [0.0, 0.62, 1.0],
                    ),
                  ),
                ),
              ),
            ),
          ),
          // Grain never leaves, at any level.
          const Positioned.fill(child: GrainOverlay()),
        ],
      ),
    );

    final Widget shaped = switch (shape) {
      VeilShape.circle => ClipOval(child: veiled),
      VeilShape.card => ClipRRect(borderRadius: _cardRadius, child: veiled),
    };

    return scale == 1.0 ? shaped : Transform.scale(scale: scale, child: shaped);
  }

  /// TileMode.decal is not a detail: with the default clamp, the edge
  /// pixels smear outwards at sigma 26 and trace the silhouette of the
  /// face against the frame — exactly what the Veil exists to hide.
  Widget _blur(double sigma, Widget child) {
    if (sigma < 0.05) return child;
    return ImageFiltered(
      imageFilter: ui.ImageFilter.blur(
        sigmaX: sigma,
        sigmaY: sigma,
        tileMode: TileMode.decal,
      ),
      child: child,
    );
  }
}

/// The warm placeholder that sits under the Veil when there is no photo
/// at all (pre-match, or a photo we are not allowed to load).
class VeilPlaceholder extends StatelessWidget {
  const VeilPlaceholder({super.key, this.icon = Icons.person_rounded});

  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFEFE3D8), Color(0xFFC9A797), Color(0xFFA87F6E)],
        ),
      ),
      child: icon == null
          ? const SizedBox.expand()
          : LayoutBuilder(
              builder: (context, constraints) => Center(
                child: Icon(
                  icon,
                  size: constraints.biggest.shortestSide * 0.38,
                  color: AppColors.paper.withValues(alpha: 0.72),
                ),
              ),
            ),
    );
  }
}
