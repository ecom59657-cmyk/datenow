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

  /// Believable live count — kept in sync with the "people online" stat
  /// tile below (1.2k ≈ 1 247).
  static const int _onlineCount = 1247;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Container(
      height: 420,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: AppRadius.brXl,
        boxShadow: [
          BoxShadow(
            color: AppColors.brandPink.withValues(alpha: 0.32),
            blurRadius: 44,
            offset: const Offset(0, 20),
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
          // 4. Foreground content.
          Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _OnlineNowChip(count: _onlineCount, label: l10n.homeOnlineNow)
                    .animate()
                    .fadeIn(duration: 400.ms, delay: 200.ms),
                const Spacer(),
                _HeroHeadline(l10n: l10n)
                    .animate()
                    .fadeIn(duration: 500.ms, delay: 120.ms)
                    .slideY(begin: 0.15, end: 0, curve: Curves.easeOut),
                const SizedBox(height: AppSpacing.lg),
                _StartDateButton(label: l10n.homeHeroCta, onPressed: onPressed)
                    .animate()
                    .fadeIn(duration: 500.ms, delay: 280.ms)
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

  @override
  Widget build(BuildContext context) {
    final titleStyle = AppTypography.h1.copyWith(
      color: Colors.white,
      height: 1.12,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(l10n.homeHeroTitleLead, style: titleStyle),
        ShaderMask(
          shaderCallback: (rect) =>
              AppColors.brandGradient.createShader(rect),
          blendMode: BlendMode.srcIn,
          child: Text(
            l10n.homeHeroTitleAccent,
            style: titleStyle,
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        Text(
          l10n.homeHeroSubtitleStrong,
          style: AppTypography.bodyStrong.copyWith(color: Colors.white),
        ),
        Text(
          l10n.homeHeroSubtitleSoft,
          style: AppTypography.body.copyWith(color: AppColors.textSecondary),
        ),
      ],
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
      imageFilter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
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
      child: spec.online
          ? Align(
              alignment: const Alignment(0.6, 0.6),
              child: Container(
                width: spec.size * 0.22,
                height: spec.size * 0.22,
                decoration: const BoxDecoration(
                  color: AppColors.online,
                  shape: BoxShape.circle,
                ),
              ),
            )
          : null,
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

/// Live social-proof pill — a pulsing green dot + count. Creates a gentle
/// "it's happening right now" pull.
class _OnlineNowChip extends StatelessWidget {
  const _OnlineNowChip({required this.count, required this.label});

  final int count;
  final String label;

  /// Group thousands with a thin space — "1 247".
  String get _formattedCount {
    final digits = count.toString();
    final buffer = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(' ');
      buffer.write(digits[i]);
    }
    return buffer.toString();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.38),
        borderRadius: AppRadius.brPill,
        border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: const BoxDecoration(
              color: AppColors.online,
              shape: BoxShape.circle,
            ),
          )
              .animate(onPlay: (c) => c.repeat(reverse: true))
              .fadeIn(duration: 900.ms)
              .then()
              .fade(begin: 1, end: 0.3, duration: 900.ms),
          const SizedBox(width: 7),
          Text(
            '$_formattedCount $label',
            style: AppTypography.caption.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w600,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}

/// The explicit click target — a full-width white pill that reads
/// unmistakably as a button against the dark hero. Gently pulses to
/// draw the eye.
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
