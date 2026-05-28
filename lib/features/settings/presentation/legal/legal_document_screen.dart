import 'package:flutter/material.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_spacing.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../../../shared/widgets/glass_card.dart';

/// Long-form legal screen — premium dark canvas with a soft magenta/violet
/// glow backdrop, a gradient-tinted hero (title + "last updated" pill),
/// and numbered sections rendered inside a single glass card with hairline
/// rules between each block. Used by both Terms of Use and Privacy Policy.
///
/// Design language:
///   • Apple / Notion / Linear / Arc — quiet density, big rhythm, no
///     decoration that doesn't carry meaning.
///   • Backdrop glow stays behind every layer (Stack base) so even a long
///     scroll never feels flat-black.
///   • Section headings get a small brand-pink "01 / 02 …" prefix so the
///     reader can skim the structure without parsing labels.
///   • Body text height 1.6 to maximise legibility on a long read.
class LegalDocumentScreen extends StatelessWidget {
  const LegalDocumentScreen({
    super.key,
    required this.title,
    required this.lastUpdated,
    required this.sections,
  });

  final String title;
  final String lastUpdated;
  final List<(String, String)> sections;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AppScaffold(
      // BackButton kept on the AppBar so the gesture is iOS-native. The
      // AppBar title stays small — the big visual identity comes from
      // the hero in the body, à la Apple Settings.
      appBar: AppBar(
        leading: const BackButton(),
        title: Text(title),
      ),
      body: Stack(
        children: [
          // Subtle radial glows (brand-pink + brand-violet) behind the
          // content — gives the dark canvas the premium "depth" cue
          // without any decoration that competes with the text.
          const _BackdropGlow(),
          ListView(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.lg,
              AppSpacing.lg,
              80,
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
                      _SectionHeading(
                        index: i + 1,
                        label: section.$1,
                      ),
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
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Backdrop — two muted radial glows (pink + violet) absolutely positioned
// behind every other layer. Pointer-transparent so it never interferes
// with scrolling or selecting text in the document.
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
// Hero — gradient-painted title + "last updated" pill. The title is the
// document name (Conditions / Privacy) rendered with the brand gradient
// via ShaderMask, so it reads as the unmistakable identity of the page
// without resorting to a separate banner image.
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
        ShaderMask(
          shaderCallback: (rect) =>
              AppColors.brandGradient.createShader(rect),
          blendMode: BlendMode.srcIn,
          child: Text(
            title,
            style: AppTypography.h1.copyWith(
              fontSize: 30,
              height: 1.1,
              letterSpacing: -0.5,
              // ShaderMask needs a non-null colour upstream; the shader
              // blends over white so any base colour works.
              color: Colors.white,
            ),
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
// Section heading — small brand-pink "01 / 02 …" prefix above the label
// so the reader can skim. The label uses bodyStrong scaled up slightly
// for a confident reading rhythm.
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

// ---------------------------------------------------------------------------
// Hairline under the section heading — a 1 px subtle gradient line that
// gives a "section opens here" cue without weight.
// ---------------------------------------------------------------------------

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
