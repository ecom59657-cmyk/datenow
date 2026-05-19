import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_spacing.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../../shared/widgets/status_pill.dart';
import '../../../profile/presentation/edit/providers/profile_photos_provider.dart';

class HomeHeader extends StatelessWidget {
  const HomeHeader({super.key, this.displayName, this.onAvatarTap});

  final String? displayName;

  /// Tapping the avatar opens the Profile space. Navigation is owned by the
  /// caller so this widget stays a pure presentation component.
  final VoidCallback? onAvatarTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final greeting = _greeting(l10n);
    final name = displayName?.split(' ').first ?? l10n.homeFallbackName;

    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$greeting,',
                style: AppTypography.body.copyWith(
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 2),
              Text(name, style: AppTypography.h2),
              const SizedBox(height: AppSpacing.xs),
              StatusPill(label: l10n.youAreOnline),
            ],
          ),
        ),
        _AvatarBadge(onTap: onAvatarTap),
      ],
    );
  }

  String _greeting(AppLocalizations l10n) {
    final hour = DateTime.now().hour;
    if (hour < 5) return l10n.homeGreetingNight;
    if (hour < 12) return l10n.homeGreetingMorning;
    if (hour < 18) return l10n.homeGreetingAfternoon;
    return l10n.homeGreetingEvening;
  }
}

class _AvatarBadge extends ConsumerWidget {
  const _AvatarBadge({this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const size = 52.0;
    final image = ref.watch(primaryProfilePhotoProvider).asData?.value;

    final Widget avatar = image != null
        ? Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              image: DecorationImage(image: image, fit: BoxFit.cover),
              border: Border.all(color: AppColors.hairline, width: 2),
            ),
          )
        : Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: AppColors.brandGradient,
              border: Border.all(color: AppColors.hairline, width: 2),
            ),
            child: const Center(
              child: Icon(Icons.person_rounded, color: Colors.white, size: 28),
            ),
          );

    if (onTap == null) return avatar;

    // Tappable: a circular ink ripple + haptic feedback signals the avatar
    // is a shortcut to the Profile space.
    return Semantics(
      button: true,
      label: AppLocalizations.of(context).navProfile,
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: avatar,
        ),
      ),
    );
  }
}
