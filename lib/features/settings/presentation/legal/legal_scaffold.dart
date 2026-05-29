import 'package:flutter/material.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_spacing.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../../../shared/widgets/glass_card.dart';

/// Reusable scaffold for the two long-form legal screens of DateNow
/// (`LegalTermsScreen`, `PrivacyPolicyScreen`).
///
/// Visual language — Apple / Tinder / Bumble :
///   • Plain white bold title (no gradient mask) — confident but not
///     flashy. The brand identity is carried by the soft pink/violet
///     glow backdrop and the small numbered prefixes, not the title.
///   • Subtle radial-glow backdrop (pink + violet) absolutely positioned,
///     IgnorePointer, behind the content. Premium "depth" cue on the
///     dark canvas without competing with the text.
///   • Numbered sections (`01 / 02 / …`) with a thin gradient hairline
///     under each heading.
///   • "Last updated" pill in brand-pink under the title.
///   • Whole body fades in once on mount (350 ms easeOut). Scrolling is
///     the default iOS BouncingScrollPhysics — fluid and native.
///   • DateNow signature footer at the bottom (hairline + monogram).
class LegalScaffold extends StatelessWidget {
  const LegalScaffold({
    super.key,
    required this.title,
    required this.lastUpdated,
    required this.sections,
  });

  final String title;
  final String lastUpdated;

  /// Ordered list of `(heading, body)` sections.
  final List<(String, String)> sections;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AppScaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: Text(title),
      ),
      body: Stack(
        children: [
          const _BackdropGlow(),
          ListView(
            // BouncingScrollPhysics is the iOS default in Material on
            // iOS — set it explicitly so Android/iPad builds also feel
            // the iOS spring inertia.
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.lg,
              AppSpacing.lg,
              AppSpacing.xxl,
            ),
            children: [
              _Hero(
                title: title,
                lastUpdatedLabel: l10n.legalLastUpdated(lastUpdated),
              ),
              const SizedBox(height: AppSpacing.xl),
              GlassCard(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  AppSpacing.lg,
                  AppSpacing.lg,
                  AppSpacing.lg,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final (i, section) in sections.indexed) ...[
                      _SectionHeading(index: i + 1, label: section.$1),
                      const SizedBox(height: 10),
                      const _HairlineRule(),
                      const SizedBox(height: 12),
                      Text(
                        section.$2,
                        style: AppTypography.body.copyWith(
                          color: AppColors.textSecondary,
                          height: 1.6,
                          letterSpacing: 0.05,
                        ),
                      ),
                      if (i < sections.length - 1)
                        const SizedBox(height: AppSpacing.xl),
                    ],
                  ],
                ),
              ),
              const _DateNowFooter(),
            ],
          ),
          // No body-level fade — the iOS push transition already provides
          // a smooth slide-and-fade entrance. Layering a 350 ms fadeIn on
          // top kept the content at near-zero opacity for the full push
          // duration, producing the "écran transparent" perception
          // reported on TestFlight.
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Backdrop glow — pointer-transparent so it never interferes with scroll
// or text selection (which is off by default on Text anyway).
// ---------------------------------------------------------------------------

class _BackdropGlow extends StatelessWidget {
  const _BackdropGlow();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Stack(
        children: [
          Positioned(
            top: -140,
            left: -80,
            child: _glow(AppColors.brandPink.withValues(alpha: 0.18), 320),
          ),
          Positioned(
            top: -100,
            right: -90,
            child: _glow(AppColors.brandViolet.withValues(alpha: 0.14), 280),
          ),
        ],
      ),
    );
  }

  Widget _glow(Color color, double size) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [color, color.withValues(alpha: 0)],
          ),
        ),
      );
}

// ---------------------------------------------------------------------------
// Hero — plain white bold title + "last updated" pill. No ShaderMask
// gradient on the title : the spec calls for Apple / Tinder / Bumble
// confidence — a single confident bold word, not a flashy paint.
// ---------------------------------------------------------------------------

class _Hero extends StatelessWidget {
  const _Hero({required this.title, required this.lastUpdatedLabel});

  final String title;
  final String lastUpdatedLabel;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: AppTypography.h1.copyWith(
            fontSize: 30,
            height: 1.1,
            letterSpacing: -0.5,
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        _LastUpdatedPill(label: lastUpdatedLabel),
      ],
    );
  }
}

class _LastUpdatedPill extends StatelessWidget {
  const _LastUpdatedPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
      decoration: BoxDecoration(
        color: AppColors.brandPink.withValues(alpha: 0.10),
        borderRadius: AppRadius.brPill,
        border: Border.all(
          color: AppColors.brandPink.withValues(alpha: 0.28),
          width: 0.6,
        ),
        boxShadow: [
          BoxShadow(
            color: AppColors.brandPink.withValues(alpha: 0.14),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Text(
        label,
        style: AppTypography.caption.copyWith(
          color: AppColors.brandPink,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.3,
          fontSize: 11,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Section heading — small brand-pink `01 / 02 / …` prefix above the
// label so the reader can skim. The label is bodyStrong scaled up
// slightly for a confident long-form reading rhythm.
// ---------------------------------------------------------------------------

class _SectionHeading extends StatelessWidget {
  const _SectionHeading({required this.index, required this.label});

  final int index;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          index.toString().padLeft(2, '0'),
          style: AppTypography.caption.copyWith(
            color: AppColors.brandPink,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.4,
            fontSize: 11,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: AppTypography.bodyStrong.copyWith(
            fontSize: 17,
            letterSpacing: 0.1,
            height: 1.25,
          ),
        ),
      ],
    );
  }
}

class _HairlineRule extends StatelessWidget {
  const _HairlineRule();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 1,
      width: 40,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            AppColors.brandPink.withValues(alpha: 0.7),
            AppColors.brandPink.withValues(alpha: 0),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// DateNow signature footer — quiet hairline + monogram + copyright.
// Closes the document with a small editorial signature, à la Apple
// "Designed by Apple in California" → but DateNow-styled.
// ---------------------------------------------------------------------------

class _DateNowFooter extends StatelessWidget {
  const _DateNowFooter();

  @override
  Widget build(BuildContext context) {
    final year = DateTime.now().year;
    return Padding(
      padding: const EdgeInsets.only(
        top: AppSpacing.xl,
        bottom: AppSpacing.md,
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 32,
              height: 1,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    AppColors.brandPink.withValues(alpha: 0.5),
                    AppColors.brandViolet.withValues(alpha: 0.35),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              'DATENOW',
              style: AppTypography.caption.copyWith(
                color: AppColors.textTertiary,
                fontWeight: FontWeight.w800,
                letterSpacing: 2.4,
                fontSize: 11,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '© $year',
              style: AppTypography.caption.copyWith(
                color: AppColors.textTertiary,
                letterSpacing: 0.4,
                fontSize: 10,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
