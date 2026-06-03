import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_spacing.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../l10n/app_localizations.dart';

/// Immersive home hero — the first thing a new user sees.
///
/// A soft wall of blurred "presences" (people online right now) sits behind
/// a warm, personal hook and the primary CTA. The goal is to land the
/// emotional pitch *and* the tap target within the first ~3 seconds.
///
/// Presentation only: [onPressed] is wired to the exact same matching flow
/// as before — the hero just makes it feel inviting.
class HomeHeroCard extends StatelessWidget {
  const HomeHeroCard({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Container(
      // Taller to host the central camera orb as the focal point with
      // generous, premium vertical rhythm around it. The hero lives inside a
      // scrolling ListView so the extra height never risks an overflow.
      height: 468,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: AppRadius.brXl,
        // More diffuse, layered glow for depth — a soft wide pink cast over a
        // subtler violet ambient, instead of one hard drop.
        boxShadow: [
          BoxShadow(
            color: AppColors.brandPink.withValues(alpha: 0.26),
            blurRadius: 60,
            spreadRadius: -6,
            offset: const Offset(0, 26),
          ),
          BoxShadow(
            color: AppColors.brandViolet.withValues(alpha: 0.13),
            blurRadius: 44,
            spreadRadius: -10,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 1. Deep base tint.
          const ColoredBox(color: AppColors.surfaceElevated),
          // 2. Blurred wall of people online right now.
          const _PresenceField(),
          // 3. Legibility scrim — keeps the hook + CTA readable over any
          //    presence behind them.
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  AppColors.background.withValues(alpha: 0.45),
                  AppColors.background.withValues(alpha: 0.05),
                  AppColors.background.withValues(alpha: 0.92),
                ],
                stops: const [0.0, 0.4, 1.0],
              ),
            ),
          ),
          // 3.5 Soft central depth glow behind the headline — diffuse and
          //     subtle, just enough to lift the title off the backdrop.
          const Align(
            alignment: Alignment.center,
            child: _CenterGlow(),
          ),
          // 3.6 Localised dark band behind the gradient title line so the pink
          //     "en vidéo floutée." pops with premium contrast. Transparent at
          //     the top (orb + "Commence un date" stay colourful), deepening to
          //     near-black across the lower-centre band where the accent line
          //     and subtext sit, then easing back out toward the CTA. Sits ABOVE
          //     the pink centre glow (cancels it there) but BELOW the text.
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.transparent,
                  Colors.transparent,
                  Colors.black.withValues(alpha: 0.55),
                  Colors.black.withValues(alpha: 0.55),
                  Colors.black.withValues(alpha: 0.18),
                ],
                stops: const [0.0, 0.42, 0.55, 0.74, 1.0],
              ),
            ),
          ),
          // 4. Foreground content — a centred column with the camera orb as
          //    the emotional focal point. Spacer flex ratios do the vertical
          //    rhythm (Apple/Spotify-style breathing) and adapt to the card
          //    height without ever overflowing.
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.lg,
              AppSpacing.lg,
              AppSpacing.xl,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const Spacer(flex: 3),
                // Focal point — premium glowing camera orb.
                const _CameraOrb()
                    .animate()
                    .fadeIn(duration: 600.ms, delay: 100.ms),
                const Spacer(flex: 3),
                _HeroHeadline(l10n: l10n)
                    .animate()
                    .fadeIn(duration: 500.ms, delay: 240.ms)
                    .slideY(begin: 0.12, end: 0, curve: Curves.easeOut),
                const Spacer(flex: 4),
                _StartDateButton(label: l10n.homeHeroCta, onPressed: onPressed)
                    .animate()
                    .fadeIn(duration: 500.ms, delay: 340.ms)
                    .slideY(begin: 0.2, end: 0, curve: Curves.easeOut),
              ],
            ),
          ),
        ],
      ),
    ).animate().fadeIn(duration: 450.ms);
  }
}

/// Hero headline + reassurance subtext.
///
/// Reproduces the validated DA: a large two-line title where the second line
/// — "en vidéo floutée." — is painted with the DateNow brand gradient (same
/// ShaderMask technique as the wordmark) so the *blurred-video* promise is
/// the first thing the eye lands on. The two-line subtext below reframes the
/// date as a calm conversation: a strong white "Parlez d'abord." over a
/// softer "Le reveal viendra ensuite." — no surprise-call pressure.
class _HeroHeadline extends StatelessWidget {
  const _HeroHeadline({required this.l10n});

  final AppLocalizations l10n;

  /// Vibrant, luminous pink→magenta accent for "en vidéo floutée." — hot,
  /// saturated and high-contrast on the dark backdrop, with a glossy light
  /// highlight at the top-left.
  static const LinearGradient _accentGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [
      Color(0xFFFFA6D4), // glossy light-pink highlight
      Color(0xFFFF2E92), // vivid pink
      Color(0xFFFF0A7B), // hot magenta
    ],
    stops: [0.0, 0.5, 1.0],
  );

  @override
  Widget build(BuildContext context) {
    // Slightly smaller than before (28) with an airier line-height for an
    // editorial, luxurious feel — centred to sit under the camera orb.
    final leadStyle = AppTypography.h1.copyWith(
      color: Colors.white,
      fontSize: 28,
      height: 1.25,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.2,
    );
    final accentStyle = leadStyle.copyWith(fontWeight: FontWeight.w800);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Title is LOCKED to exactly two lines — one phrase per line, never
        // auto-wrapped (maxLines:1 + softWrap:false on each). Both lines share
        // a single FittedBox(scaleDown) so on a narrow device they shrink
        // together and stay aligned instead of wrapping or overflowing; on a
        // standard iPhone they render at full size.
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                l10n.homeHeroTitleLead,
                maxLines: 1,
                softWrap: false,
                textAlign: TextAlign.center,
                style: leadStyle,
              ),
              // A breath between the two lines for editorial spacing.
              const SizedBox(height: 6),
              // Line 2 — vibrant pink→magenta accent on the "blurred video"
              // promise.
              ShaderMask(
                shaderCallback: (rect) => _accentGradient.createShader(rect),
                blendMode: BlendMode.srcIn,
                child: Text(
                  l10n.homeHeroTitleAccent,
                  maxLines: 1,
                  softWrap: false,
                  textAlign: TextAlign.center,
                  style: accentStyle,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        // Primary reassurance line — strong, present.
        Text(
          l10n.homeHeroSubtitleStrong,
          maxLines: 1,
          textAlign: TextAlign.center,
          overflow: TextOverflow.ellipsis,
          style: AppTypography.h3.copyWith(
            color: Colors.white,
            fontWeight: FontWeight.w700,
          ),
        ),
        // Clear separation, then the softer secondary line.
        const SizedBox(height: AppSpacing.xs),
        Text(
          l10n.homeHeroSubtitleSoft,
          maxLines: 1,
          textAlign: TextAlign.center,
          overflow: TextOverflow.ellipsis,
          style: AppTypography.body.copyWith(color: AppColors.textSecondary),
        ),
      ],
    );
  }
}

/// The emotional focal point — a large, premium glowing camera orb. A softly
/// translucent circle with a subtle hairline border and a diffuse pink/violet
/// halo, a video-camera-with-heart icon at its centre. Reads as "live, human,
/// premium" without any surprise-call aggression. Gently breathes.
class _CameraOrb extends StatelessWidget {
  const _CameraOrb();

  static const double _size = 104;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: _size,
      height: _size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        // Faintly translucent glass fill.
        gradient: RadialGradient(
          colors: [
            Colors.white.withValues(alpha: 0.13),
            Colors.white.withValues(alpha: 0.03),
          ],
        ),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.22),
          width: 1,
        ),
        // Diffuse pink × violet halo for depth.
        boxShadow: [
          BoxShadow(
            color: AppColors.brandPink.withValues(alpha: 0.42),
            blurRadius: 38,
            spreadRadius: 2,
          ),
          BoxShadow(
            color: AppColors.brandViolet.withValues(alpha: 0.30),
            blurRadius: 56,
            spreadRadius: 8,
          ),
        ],
      ),
      child: const _VideoHeartIcon(
        cameraSize: 46,
        cameraColor: Colors.white,
        heartColor: AppColors.brandPink,
      ),
    )
        .animate(onPlay: (c) => c.repeat(reverse: true))
        .scale(
          duration: 2800.ms,
          begin: const Offset(1, 1),
          end: const Offset(1.045, 1.045),
          curve: Curves.easeInOut,
        );
  }
}

/// Soft, diffuse radial glow placed at the card centre to give the headline
/// a subtle sense of depth — premium, never loud. Decorative + non-blocking.
class _CenterGlow extends StatelessWidget {
  const _CenterGlow();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: 340,
        height: 340,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [
              AppColors.brandPink.withValues(alpha: 0.16),
              AppColors.brandPink.withValues(alpha: 0.04),
              AppColors.brandPink.withValues(alpha: 0),
            ],
            stops: const [0.0, 0.5, 1.0],
          ),
        ),
      ),
    );
  }
}

/// The blurred backdrop — a loose grid of circular "presences" representing
/// online profiles, heavily blurred so faces stay a promise, not a preview.
/// This deliberately echoes DateNow's signature: faces are revealed only
/// once a live date begins.
class _PresenceField extends StatelessWidget {
  const _PresenceField();

  // (top, left, right, size, gradient, online) — null left/right = unset.
  static const _orbs = <_OrbSpec>[
    _OrbSpec(top: -16, left: -24, size: 132, online: true),
    _OrbSpec(top: 8, left: 104, size: 104, online: false),
    _OrbSpec(top: -28, right: -18, size: 124, online: true),
    _OrbSpec(top: 96, left: 18, size: 96, online: false),
    _OrbSpec(top: 118, right: 30, size: 112, online: true),
    _OrbSpec(top: 150, left: 128, size: 88, online: false),
  ];

  @override
  Widget build(BuildContext context) {
    return ImageFiltered(
      // Softer blur (was 18) so the silhouettes read as real people behind the
      // glass — present and human — while faces stay unidentifiable.
      imageFilter: ImageFilter.blur(sigmaX: 11, sigmaY: 11),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (final (i, orb) in _orbs.indexed)
            Positioned(
              top: orb.top,
              left: orb.left,
              right: orb.right,
              child: _PresenceOrb(spec: orb, seed: i),
            ),
        ],
      ),
    );
  }
}

class _OrbSpec {
  const _OrbSpec({
    required this.top,
    required this.size,
    required this.online,
    this.left,
    this.right,
  });

  final double top;
  final double? left;
  final double? right;
  final double size;
  final bool online;
}

/// A single blurred presence. Gentle, slightly desynced pulsing makes the
/// field feel alive without being distracting.
class _PresenceOrb extends StatelessWidget {
  const _PresenceOrb({required this.spec, required this.seed});

  final _OrbSpec spec;
  final int seed;

  static const _gradients = <List<Color>>[
    [AppColors.brandPink, AppColors.brandViolet],
    [AppColors.brandViolet, AppColors.brandBlue],
    [AppColors.brandBlue, AppColors.brandPink],
  ];

  @override
  Widget build(BuildContext context) {
    final colors = _gradients[seed % _gradients.length];
    final orb = Container(
      width: spec.size,
      height: spec.size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors,
        ),
      ),
      child: Stack(
        children: [
          // Faint human silhouette so the blurred field reads as REAL people
          // (not an abstract gradient blob) — anonymised by the field blur.
          Center(
            child: Icon(
              Icons.person_rounded,
              size: spec.size * 0.62,
              color: Colors.white.withValues(alpha: 0.26),
            ),
          ),
          if (spec.online)
            Align(
              alignment: const Alignment(0.7, 0.7),
              child: Container(
                width: spec.size * 0.2,
                height: spec.size * 0.2,
                decoration: BoxDecoration(
                  color: AppColors.online,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.5),
                    width: 1.5,
                  ),
                ),
              ),
            ),
        ],
      ),
    );

    return orb
        .animate(onPlay: (c) => c.repeat(reverse: true))
        .scale(
          duration: (2600 + seed * 220).ms,
          begin: const Offset(0.94, 0.94),
          end: const Offset(1.04, 1.04),
          curve: Curves.easeInOut,
        );
  }
}

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
                    letterSpacing: 0.2,
                  ),
                ),
              ),
            ],
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
  const _VideoHeartIcon({
    this.cameraSize = 30,
    this.cameraColor = AppColors.brandPink,
    this.heartColor = AppColors.brandViolet,
  });

  /// Camera glyph size. The heart badge scales with it.
  final double cameraSize;
  final Color cameraColor;
  final Color heartColor;

  @override
  Widget build(BuildContext context) {
    final heart = cameraSize * 0.46;
    return SizedBox(
      width: cameraSize + 6,
      height: cameraSize + 2,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Icon(
            Icons.videocam_rounded,
            size: cameraSize,
            color: cameraColor,
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
              child: Icon(
                Icons.favorite_rounded,
                size: heart,
                color: heartColor,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
