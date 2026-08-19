import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// A fine film grain laid over whatever sits below it.
///
/// Grain is what keeps large flat ivory areas from looking like empty CSS,
/// and it is the one layer of [Veil] that never goes away — including
/// after a reveal. It must therefore be cheap: the texture is generated
/// **once** per process into a [ui.Image] and repeated by an [ImageShader].
/// Decoding an asset every frame (or rebuilding the noise per paint) shows
/// up immediately as jank on the call and reveal screens.
class GrainOverlay extends StatefulWidget {
  const GrainOverlay({
    super.key,
    this.opacity = 0.03,
    this.child,
  });

  /// 0.03 is the house value — visible as texture, never as noise.
  final double opacity;
  final Widget? child;

  @override
  State<GrainOverlay> createState() => _GrainOverlayState();
}

class _GrainOverlayState extends State<GrainOverlay> {
  static ui.Image? _texture;
  static Future<ui.Image>? _pending;

  @override
  void initState() {
    super.initState();
    if (_texture != null) return;
    (_pending ??= _buildTexture()).then((image) {
      _texture = image;
      if (mounted) setState(() {});
    });
  }

  /// 128² of deterministic monochrome noise. Fixed seed so the grain is
  /// identical across runs and across the two devices in a call — it is
  /// part of the look, not a random artefact.
  static Future<ui.Image> _buildTexture() {
    const size = 128;
    final rnd = math.Random(0x0A7E);
    final pixels = Uint8List(size * size * 4);
    for (var i = 0; i < size * size; i++) {
      final v = 96 + rnd.nextInt(160);
      pixels[i * 4] = v;
      pixels[i * 4 + 1] = v;
      pixels[i * 4 + 2] = v;
      pixels[i * 4 + 3] = 255;
    }
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      pixels,
      size,
      size,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return completer.future;
  }

  @override
  Widget build(BuildContext context) {
    final texture = _texture;
    final grain = texture == null
        ? const SizedBox.shrink()
        : IgnorePointer(
            child: RepaintBoundary(
              child: CustomPaint(
                painter: _GrainPainter(
                  texture: texture,
                  opacity: widget.opacity,
                ),
                size: Size.infinite,
              ),
            ),
          );

    if (widget.child == null) return grain;
    return Stack(
      fit: StackFit.passthrough,
      children: [
        widget.child!,
        Positioned.fill(child: grain),
      ],
    );
  }
}

class _GrainPainter extends CustomPainter {
  const _GrainPainter({required this.texture, required this.opacity});

  final ui.Image texture;
  final double opacity;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final paint = Paint()
      ..shader = ImageShader(
        texture,
        TileMode.repeated,
        TileMode.repeated,
        Matrix4.identity().storage,
      )
      ..blendMode = BlendMode.overlay;
    // saveLayer carries the alpha: a shader ignores paint.color, so this is
    // the only way to dial the grain down to a few percent.
    canvas.saveLayer(
      rect,
      Paint()..color = Colors.white.withValues(alpha: opacity),
    );
    canvas.drawRect(rect, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_GrainPainter old) =>
      old.texture != texture || old.opacity != opacity;
}
