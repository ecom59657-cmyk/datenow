import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/app_scaffold.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../profile/presentation/edit/providers/profile_photos_provider.dart';
import '../../profile_setup/domain/interest.dart';
import '../data/matched_profile_repository.dart';
import '../domain/match_score.dart';
import '../domain/matched_profile.dart';
import 'widgets/compatibility_badge.dart';

/// Read-only profile card for a MATCHED peer, opened from the conversation
/// header. Access is enforced server-side by the `get_matched_profile` RPC —
/// this screen only renders what the RPC returns and shows a calm
/// "Profil indisponible" on any failure (incl. no-match).
class MatchedProfileScreen extends ConsumerWidget {
  const MatchedProfileScreen({super.key, required this.userId});

  final String userId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(matchedProfileProvider(userId));
    return AppScaffold(
      glowIntensity: 0.6,
      applyHorizontalPadding: false,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: const BackButton(),
      ),
      body: async.when(
        loading: () => const Center(child: LoadingIndicator()),
        error: (_, _) => const _Unavailable(),
        data: (profile) => _Content(profile: profile),
      ),
    );
  }
}

class _Content extends StatelessWidget {
  const _Content({required this.profile});

  final MatchedProfile profile;

  @override
  Widget build(BuildContext context) {
    final name = profile.firstName ?? 'Profil';
    final title = profile.age != null ? '$name, ${profile.age}' : name;
    // Hero is sized to a share of the viewport (not a width-based aspect
    // ratio that consumed ~54% of the screen on a 6.1"). ~40%, clamped, keeps
    // it the dominant portrait while leaving room for name + badge + every
    // interest chip above the fold on a standard iPhone. Small screens /
    // very large Dynamic Type still scroll via the enclosing ListView.
    final heroHeight =
        (MediaQuery.of(context).size.height * 0.40).clamp(260.0, 420.0);
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.sm,
        AppSpacing.lg,
        AppSpacing.lg,
      ),
      children: [
        _PhotoCard(path: profile.mainPhotoPath, height: heroHeight),
        const SizedBox(height: AppSpacing.md),
        Text(title, style: AppTypography.display.copyWith(fontSize: 30)),
        const SizedBox(height: AppSpacing.sm),
        Align(
          alignment: Alignment.centerLeft,
          child: CompatibilityBadge(
            score: MatchScore(
              percentage: profile.compatibilityScore,
              breakdown: const {},
            ),
          ),
        ),
        if (profile.interests.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.lg),
          Text('Centres d’intérêt', style: AppTypography.h3),
          const SizedBox(height: AppSpacing.sm),
          _InterestChips(interests: profile.interests),
        ],
      ],
    );
  }
}

/// Large rounded hero photo. Downloads the bytes through the existing
/// matched-gated storage pipeline; falls back to the brand gradient when the
/// peer has no approved photo or the download fails.
class _PhotoCard extends ConsumerWidget {
  const _PhotoCard({required this.path, required this.height});

  final String? path;
  final double height;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ClipRRect(
      borderRadius: AppRadius.brXl,
      child: SizedBox(
        height: height,
        width: double.infinity,
        // Session-cached: fetched once per path, reused on re-entry instead
        // of re-downloaded (loading spinner only on the first fetch).
        child: path == null
            ? const _PhotoFallback()
            : ref.watch(photoBytesProvider(path!)).when(
                loading: () => const ColoredBox(
                  color: AppColors.surface,
                  child: Center(child: LoadingIndicator()),
                ),
                error: (_, __) => const _PhotoFallback(),
                data: (bytes) => bytes == null
                    ? const _PhotoFallback()
                    : Image.memory(bytes, fit: BoxFit.cover),
              ),
      ),
    );
  }
}

class _PhotoFallback extends StatelessWidget {
  const _PhotoFallback();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(gradient: AppColors.brandGradient),
      child: Center(
        child: Icon(Icons.person_rounded, color: Colors.white, size: 72),
      ),
    );
  }
}

/// Read-only interest chips — same look as the profile-setup selected chip,
/// without any tap/toggle affordance.
class _InterestChips extends StatelessWidget {
  const _InterestChips({required this.interests});

  final List<Interest> interests;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final interest in interests)
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: 8,
            ),
            decoration: BoxDecoration(
              color: AppColors.pinkSoft,
              borderRadius: AppRadius.brPill,
              border: Border.all(color: AppColors.brandPink, width: 1),
            ),
            child: Text(
              interest.label(l10n),
              style: AppTypography.bodyStrong.copyWith(
                color: AppColors.textPrimary,
              ),
            ),
          ),
      ],
    );
  }
}

class _Unavailable extends StatelessWidget {
  const _Unavailable();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.lock_outline_rounded,
              size: 56, color: AppColors.textTertiary),
          const SizedBox(height: AppSpacing.md),
          Text('Profil indisponible',
              textAlign: TextAlign.center, style: AppTypography.h2),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Ce profil n’est accessible qu’avec un match actif.',
            textAlign: TextAlign.center,
            style: AppTypography.body.copyWith(color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }
}
