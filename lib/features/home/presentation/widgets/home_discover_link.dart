import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_spacing.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../l10n/app_localizations.dart';

/// Secondary CTA on Home — a premium editorial mini-card pointing to the
/// weekly Discover screen.
///
/// Visual contract:
///   • Mini-card (not a bare link). Glass inner surface clipped inside a
///     thin gradient ring (brand-pink → brand-violet) with a soft double
///     glow underneath. Reads as a real product surface, à la Apple Music
///     "For You" tile / Linear sidebar item.
///   • Tiny pill at top — "Nouveaux cette semaine" — signals editorial
///     freshness without taking visual weight.
///   • Title row : sparkle violet + "Découvrir mes profils" in bodyStrong
///     18 pt — confident but not as loud as the white live-pill above.
///   • Hint : "Compatibles, choisis pour toi" in textSecondary,
///     height 1.4 for breathing room.
///   • Bottom CTA : `→ Voir mes propositions` painted with the brand
///     gradient via ShaderMask — the only saturated colour element on
///     the card, focusing the eye on the action.
///   • Press feedback : scale 0.985 on tap (140 ms easeOut) + brand-pink
///     splash. No continuous pulse — a list-of-suggestions surface must
///     never feel like a flashing notification.
///   • Arrival animation : single fadeIn + slide-up, delayed 380 ms so
///     the eye lands on the white live-pill first.
class HomeDiscoverLink extends StatefulWidget {
  const HomeDiscoverLink({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  State<HomeDiscoverLink> createState() => _HomeDiscoverLinkState();
}

class _HomeDiscoverLinkState extends State<HomeDiscoverLink> {
  /// `true` between an InkWell `onHighlightChanged(true)` and
  /// `onHighlightChanged(false)` — drives the press-scale animation.
  bool _pressed = false;

  /// Inner radius = outer radius − ring thickness, so the gradient ring
  /// reads as exactly 1 px even when the corners are tight.
  static const double _outerRadius = 24; // matches AppRadius.brLg
  static const double _ringThickness = 1;
  static const double _innerRadius = _outerRadius - _ringThickness;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AnimatedScale(
      scale: _pressed ? 0.985 : 1.0,
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOut,
      child: _buildCard(l10n),
    )
        // Single elegant entrance — the user must perceive the card as
        // arriving after the hero CTA, not competing with it.
        .animate()
        .fadeIn(duration: 500.ms, delay: 380.ms)
        .slideY(begin: 0.16, end: 0, curve: Curves.easeOut);
  }

  Widget _buildCard(AppLocalizations l10n) {
    return Container(
      // Outer layer = the gradient ring + glow. We paint the gradient as
      // the container's fill and clip the inner Material on top so only
      // a 1 px rim of the gradient is visible.
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(_outerRadius),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0x6BFF3D7F), // bordeaux α≈42 %
            Color(0x5CB936FF), // bordeauxLight α≈36 %
          ],
        ),
        boxShadow: [
          // Two stacked glows — pink dominant near, violet softer further.
          BoxShadow(
            color: AppColors.bordeaux.withValues(alpha: 0.18),
            blurRadius: 22,
            offset: const Offset(0, 8),
          ),
          BoxShadow(
            color: AppColors.bordeauxLight.withValues(alpha: 0.12),
            blurRadius: 28,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      padding: const EdgeInsets.all(_ringThickness),
      child: Material(
        color: AppColors.surface,
        borderRadius: const BorderRadius.all(Radius.circular(_innerRadius)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: widget.onPressed,
          // Press / release / cancel all flow through here — we mirror
          // the highlight state into the scale animation.
          onHighlightChanged: (highlighted) {
            if (!mounted || highlighted == _pressed) return;
            setState(() => _pressed = highlighted);
          },
          splashColor: AppColors.bordeaux.withValues(alpha: 0.12),
          highlightColor: AppColors.bordeauxLight.withValues(alpha: 0.06),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.md,
              AppSpacing.lg,
              AppSpacing.md,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _Badge(label: l10n.homeDiscoverProfilesBadge),
                const SizedBox(height: 14),
                _TitleRow(label: l10n.homeDiscoverProfilesCta),
                const SizedBox(height: 6),
                Text(
                  l10n.homeDiscoverProfilesHint,
                  style: AppTypography.body.copyWith(
                    color: AppColors.textSecondary,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 14),
                _BottomCta(label: l10n.homeDiscoverProfilesAction),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Top pill — "Nouveaux cette semaine" / "New this week". All-caps, tight
// letter-spacing, brand-pink at low saturation so it reads as editorial
// metadata, never as the action target.
// ---------------------------------------------------------------------------

class _Badge extends StatelessWidget {
  const _Badge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.bordeaux.withValues(alpha: 0.10),
        borderRadius: AppRadius.brPill,
        border: Border.all(
          color: AppColors.bordeaux.withValues(alpha: 0.30),
          width: 0.6,
        ),
      ),
      child: Text(
        label.toUpperCase(),
        style: AppTypography.caption.copyWith(
          color: AppColors.bordeaux,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.0,
          fontSize: 10.5,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Title row — sparkle violet (curation cue, vs the pink ♥ of live) +
// the bold white title. `Flexible` so the title wraps gracefully on
// iPhone SE if the locale produces a longer string.
// ---------------------------------------------------------------------------

class _TitleRow extends StatelessWidget {
  const _TitleRow({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const Icon(
          Icons.auto_awesome_rounded,
          size: 18,
          color: AppColors.bordeauxLight,
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            label,
            style: AppTypography.bodyStrong.copyWith(
              fontSize: 18,
              letterSpacing: 0.1,
              height: 1.2,
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Bottom action — `→ Voir mes propositions` painted entirely with the
// brand gradient via ShaderMask. Pulls the eye to the action without
// having to add a separate button — the whole card is the button.
// ---------------------------------------------------------------------------

class _BottomCta extends StatelessWidget {
  const _BottomCta({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      shaderCallback: (rect) => AppColors.signatureGradient.createShader(rect),
      blendMode: BlendMode.srcIn,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Icon(
            Icons.arrow_forward_rounded,
            size: 16,
            color: Colors.white, // ShaderMask repaints over white
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              style: AppTypography.button.copyWith(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.4,
                color: Colors.white,
              ),
              maxLines: 1,
              overflow: TextOverflow.fade,
              softWrap: false,
            ),
          ),
        ],
      ),
    );
  }
}
