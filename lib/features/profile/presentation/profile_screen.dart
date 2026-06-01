import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/app_routes.dart';
import '../../../app/scaffold/active_tab.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../core/config/feature_flags.dart';
import '../../../core/utils/display_name.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/app_button.dart';
import '../../../shared/widgets/app_scaffold.dart';
import '../../../shared/widgets/glass_card.dart';
import '../../auth/presentation/providers/auth_provider.dart';
import '../../identity/data/identity_repository.dart';
import '../../profile_setup/presentation/providers/profile_provider.dart';
import '../../subscription/presentation/providers/subscription_provider.dart';
import 'edit/providers/profile_photos_provider.dart';

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen>
    with TabScrollResetMixin {
  @override
  int get tabIndex => 3; // Home=0, Discover=1, Messages=2, Profile=3

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final user = ref.watch(currentUserProvider);
    // Same precedence as Home: profile.firstName > user.displayName
    // (with @-guard) > localised fallback. Email is NEVER shown in
    // the profile card — Apple Private Relay aliases would leak
    // otherwise (see core/utils/display_name.dart).
    final profile = ref.watch(currentProfileProvider).asData?.value;
    final humaneName = resolveUserDisplayName(profile, user);
    final cardSubtitle = (profile?.isComplete ?? false)
        ? l10n.profileCardSubtitleComplete
        : l10n.profileCardSubtitleDefault;

    return AppScaffold(
      body: ListView(
        controller: tabScrollController,
        padding: const EdgeInsets.only(bottom: 120),
        physics: const BouncingScrollPhysics(),
        children: [
          const SizedBox(height: AppSpacing.md),
          Text(l10n.profileTitle, style: AppTypography.h1),
          const SizedBox(height: AppSpacing.lg),
          GlassCard(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Row(
              children: [
                const _ProfileAvatar(),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        humaneName ?? l10n.profileAnonymousName,
                        style: AppTypography.h3,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        cardSubtitle,
                        style: AppTypography.body.copyWith(
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // Identity-verification banner — Phase 5 of the Didit rollout.
          // Renders only when the gate is enabled AND the caller is not
          // yet verified. Provider error / loading also hides it so we
          // never flash a misleading "verify now" prompt on a transient
          // RPC blip. The full Find-date gate (in `home_screen.dart`)
          // already fails-closed, so a hidden banner here is not a hole.
          if (FeatureFlags.requireIdentityVerification) ...[
            Consumer(
              builder: (context, ref, _) {
                final verified = ref
                        .watch(hasVerifiedIdentityProvider)
                        .asData
                        ?.value ??
                    true;
                if (verified) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.md),
                  child: _IdentityBanner(
                    onTap: () => context
                        .pushNamed(AppRoute.identityVerification.name),
                  ),
                );
              },
            ),
          ],
          const SizedBox(height: AppSpacing.lg),
          _SectionTile(
            icon: Icons.person_outline_rounded,
            label: l10n.profilePersonalEntry,
            subtitle: l10n.profilePersonalSubtitle,
            onTap: () => context.pushNamed(AppRoute.editProfile.name),
          ),
          _SectionTile(
            icon: Icons.tune_rounded,
            label: l10n.profilePreferences,
            subtitle: l10n.profilePreferencesSubtitle,
            onTap: () => context.pushNamed(AppRoute.editPreferences.name),
          ),
          _SectionTile(
            icon: Icons.photo_library_outlined,
            label: l10n.profilePhotos,
            subtitle: l10n.profilePhotosSubtitle,
            onTap: () => context.pushNamed(AppRoute.editPhotos.name),
          ),
          _SectionTile(
            icon: Icons.chat_bubble_outline_rounded,
            label: l10n.profileMessagesEntry,
            subtitle: l10n.profileMessagesEntrySubtitle,
            onTap: () => context.pushNamed(AppRoute.messages.name),
          ),
          _SectionTile(
            icon: Icons.settings_outlined,
            label: l10n.profileSettings,
            subtitle: l10n.profileSettingsSubtitle,
            onTap: () => context.pushNamed(AppRoute.settings.name),
          ),
          // Subscription entry — copy adapts to whether the user is
          // already Premium. Falls back to "Discover" when the
          // subscription stream is still loading, so a first paint
          // never reads as a "manage" call-to-action to a free user.
          Builder(builder: (context) {
            final isPremium = ref
                    .watch(subscriptionStateProvider)
                    .asData
                    ?.value
                    .isPremium ??
                false;
            return _SectionTile(
              icon: Icons.workspace_premium_rounded,
              label: l10n.profileSubscription,
              subtitle: isPremium
                  ? l10n.profileSubscriptionManage
                  : l10n.profileSubscriptionDiscover,
              onTap: () =>
                  context.pushNamed(AppRoute.settingsSubscription.name),
            );
          }),
          const SizedBox(height: AppSpacing.xl),
          AppButton(
            label: l10n.profileSignOut,
            variant: AppButtonVariant.secondary,
            onPressed: () =>
                ref.read(authControllerProvider.notifier).signOut(),
          ),
        ],
      ),
    );
  }
}

/// Avatar shown in the user's own profile card. Renders the real primary
/// photo if available — otherwise falls back to the brand-gradient circle
/// used elsewhere. This is intentionally **the only place** outside of the
/// post-call reveal where a profile photo surfaces (and only for self).
class _ProfileAvatar extends ConsumerWidget {
  const _ProfileAvatar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const size = 64.0;
    final photoAsync = ref.watch(primaryProfilePhotoProvider);
    final image = photoAsync.asData?.value;

    if (image != null) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          image: DecorationImage(image: image, fit: BoxFit.cover),
          border: Border.all(color: AppColors.hairline, width: 2),
          boxShadow: [
            BoxShadow(
              color: AppColors.brandPink.withValues(alpha: 0.25),
              blurRadius: 18,
              spreadRadius: 1,
            ),
          ],
        ),
      );
    }

    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        gradient: AppColors.brandGradient,
      ),
      child: const Icon(Icons.person_rounded, color: Colors.white, size: 32),
    );
  }
}

class _SectionTile extends StatelessWidget {
  const _SectionTile({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: GlassCard(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.md,
        ),
        onTap: onTap,
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(AppSpacing.sm),
              decoration: BoxDecoration(
                color: AppColors.pinkSoft,
                borderRadius: AppRadius.brSm,
              ),
              child: Icon(icon, color: AppColors.brandPink, size: 20),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: AppTypography.bodyStrong),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: AppTypography.caption.copyWith(
                      color: AppColors.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded,
                color: AppColors.textTertiary),
          ],
        ),
      ),
    );
  }
}

/// Non-blocking nudge shown at the top of the Profile screen when the
/// signed-in user has not yet completed the Didit identity flow.
///
/// Mirrors the warm-amber palette used for "vérification en cours"
/// elsewhere (e.g. the photo moderation `manual_review` badge), so
/// the visual language stays "action needed, not error". The whole
/// banner is tappable — single CTA, no secondary action, no dismiss
/// button (the user can simply ignore it; the find-date gate handles
/// the actual block).
///
/// TODO(i18n-identity): strings hardcoded FR until Phase 5+ stabilises.
class _IdentityBanner extends StatelessWidget {
  const _IdentityBanner({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: AppRadius.brLg,
      child: InkWell(
        onTap: onTap,
        borderRadius: AppRadius.brLg,
        child: Container(
          padding: const EdgeInsets.all(AppSpacing.md),
          decoration: BoxDecoration(
            color: AppColors.warning.withValues(alpha: 0.10),
            borderRadius: AppRadius.brLg,
            border: Border.all(
              color: AppColors.warning.withValues(alpha: 0.35),
            ),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.shield_outlined,
                color: AppColors.warning,
                size: 24,
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Vérifie ton identité',
                      style: AppTypography.bodyStrong,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Obligatoire pour lancer un date — ~2 min.',
                      style: AppTypography.caption.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.chevron_right_rounded,
                color: AppColors.warning,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
