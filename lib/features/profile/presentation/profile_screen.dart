import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/app_routes.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/app_button.dart';
import '../../../shared/widgets/app_scaffold.dart';
import '../../../shared/widgets/glass_card.dart';
import '../../auth/presentation/providers/auth_provider.dart';
import 'edit/providers/profile_photos_provider.dart';

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final user = ref.watch(currentUserProvider);

    return AppScaffold(
      body: ListView(
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
                        user?.displayName ?? l10n.profileAnonymousName,
                        style: AppTypography.h3,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        user?.email ?? l10n.profileNotSignedIn,
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
