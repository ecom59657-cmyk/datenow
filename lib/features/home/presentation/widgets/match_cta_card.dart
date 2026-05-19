import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_spacing.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../l10n/app_localizations.dart';

/// Warm, multi-stop CTA gradient — rose → magenta → violet, tuned to feel
/// like an evening "date" ambiance rather than a flat brand fill.
const LinearGradient _ctaGradient = LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [
    Color(0xFFFF6A9C),
    Color(0xFFFF3D7F),
    Color(0xFFC23DF0),
    Color(0xFF8E3DFF),
  ],
  stops: [0.0, 0.32, 0.72, 1.0],
);

/// Hero CTA inviting the user to start a live video date.
///
/// The whole card is tappable, but the action is anchored on an explicit,
/// high-contrast pill button so a first-time user immediately sees *where*
/// to tap to launch matching. Tap → matching screen.
///
/// Visually it's the focal point of the home screen: a breathing colored
/// halo, layered depth shadows, soft light blobs and a top sheen give it a
/// premium, immersive, "soirée" feel without hiding the content inside.
class MatchCtaCard extends StatelessWidget {
  const MatchCtaCard({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Stack(
      children: [
        // Breathing ambient halo behind the card — pulls the eye straight
        // to the CTA without competing with the text/button on top of it.
        const Positioned.fill(child: _AmbientGlow()),
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onPressed,
            borderRadius: AppRadius.brXl,
            child: Container(
              decoration: BoxDecoration(
                gradient: _ctaGradient,
                borderRadius: AppRadius.brXl,
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.12),
                ),
                boxShadow: [
                  // Depth — a grounded dark shadow…
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.45),
                    blurRadius: 24,
                    offset: const Offset(0, 12),
                  ),
                  // …plus a colored glow that bleeds the brand into the page.
                  BoxShadow(
                    color: AppColors.brandPink.withValues(alpha: 0.45),
                    blurRadius: 36,
                    offset: const Offset(0, 16),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: AppRadius.brXl,
                child: Stack(
                  children: [
                    // Soft light blobs — depth + a warm, candle-lit texture.
                    const Positioned(
                      top: -50,
                      right: -30,
                      child: _GlowBlob(
                        size: 150,
                        color: Color(0xFFFFC2D6),
                        opacity: 0.55,
                      ),
                    ),
                    const Positioned(
                      bottom: -60,
                      left: -40,
                      child: _GlowBlob(
                        size: 170,
                        color: Color(0xFF7C4DFF),
                        opacity: 0.5,
                      ),
                    ),
                    // Top sheen — a gentle highlight for a glassy, immersive feel.
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.white.withValues(alpha: 0.14),
                              Colors.white.withValues(alpha: 0.0),
                            ],
                          ),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(AppSpacing.lg),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l10n.findDateHook,
                            style: AppTypography.h2.copyWith(
                              color: Colors.white,
                              shadows: [
                                Shadow(
                                  color: Colors.black.withValues(alpha: 0.25),
                                  blurRadius: 8,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: AppSpacing.xs),
                          Text(
                            l10n.findDateSubtitle,
                            style: AppTypography.body.copyWith(
                              color: Colors.white.withValues(alpha: 0.9),
                              height: 1.4,
                            ),
                          ),
                          const SizedBox(height: AppSpacing.lg),
                          _StartDateButton(
                            label: l10n.findDateTitle,
                            onPressed: onPressed,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    ).animate().fadeIn(duration: 500.ms).slideY(begin: 0.1, end: 0);
  }
}

/// Slow breathing colored halo sitting behind the card. It scales and fades
/// in a gentle loop so the CTA softly "pulses" with light — premium and
/// emotional, not distracting.
class _AmbientGlow extends StatelessWidget {
  const _AmbientGlow();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        margin: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          borderRadius: AppRadius.brXl,
          boxShadow: [
            BoxShadow(
              color: AppColors.brandPink.withValues(alpha: 0.5),
              blurRadius: 44,
              spreadRadius: 2,
            ),
            BoxShadow(
              color: AppColors.brandViolet.withValues(alpha: 0.45),
              blurRadius: 60,
              spreadRadius: 6,
              offset: const Offset(0, 18),
            ),
          ],
        ),
      ),
    )
        .animate(onPlay: (c) => c.repeat(reverse: true))
        .scaleXY(
          begin: 0.97,
          end: 1.03,
          duration: 2600.ms,
          curve: Curves.easeInOut,
        )
        .fadeIn(begin: 0.6, duration: 2600.ms, curve: Curves.easeInOut);
  }
}

/// A soft circular light source used to texture the card background and
/// give it depth, like distant lights at an evening date.
class _GlowBlob extends StatelessWidget {
  const _GlowBlob({
    required this.size,
    required this.color,
    required this.opacity,
  });

  final double size;
  final Color color;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [
            color.withValues(alpha: opacity),
            color.withValues(alpha: 0.0),
          ],
        ),
      ),
    );
  }
}

/// The explicit click target: a full-width white pill that visually reads
/// as a button against the gradient card. Gently pulses to draw the eye.
class _StartDateButton extends StatelessWidget {
  const _StartDateButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: AppRadius.brPill,
      elevation: 0,
      shadowColor: Colors.transparent,
      child: Ink(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: AppRadius.brPill,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.18),
              blurRadius: 14,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: InkWell(
          onTap: onPressed,
          borderRadius: AppRadius.brPill,
          child: Container(
            height: 62,
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            alignment: Alignment.center,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const _VideoHeartIcon(),
                const SizedBox(width: AppSpacing.sm),
                Flexible(
                  child: Text(
                    label,
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.button.copyWith(
                      color: AppColors.brandPink,
                      fontWeight: FontWeight.w700,
                      fontSize: 17,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    )
        .animate(onPlay: (c) => c.repeat(reverse: true))
        .scale(
          duration: 1600.ms,
          begin: const Offset(1, 1),
          end: const Offset(1.03, 1.03),
          curve: Curves.easeInOut,
        );
  }
}

/// Video-call icon with a small heart badge — signals "live video date"
/// and "meeting someone" in one glyph, matching the DateNow identity.
class _VideoHeartIcon extends StatelessWidget {
  const _VideoHeartIcon();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 32,
      height: 28,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          const Icon(
            Icons.videocam_rounded,
            size: 28,
            color: AppColors.brandPink,
          ),
          Positioned(
            right: -3,
            top: -4,
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: const BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.favorite_rounded,
                size: 13,
                color: AppColors.brandViolet,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
