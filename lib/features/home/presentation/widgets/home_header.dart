import 'package:flutter/material.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_spacing.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../shared/widgets/status_pill.dart';

class HomeHeader extends StatelessWidget {
  const HomeHeader({super.key, this.displayName});

  final String? displayName;

  @override
  Widget build(BuildContext context) {
    final greeting = _greeting();
    final name = displayName?.split(' ').first ?? 'there';

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
              const StatusPill(label: 'You are online'),
            ],
          ),
        ),
        const _AvatarBadge(),
      ],
    );
  }

  String _greeting() {
    final hour = DateTime.now().hour;
    if (hour < 5) return 'Good night';
    if (hour < 12) return 'Good morning';
    if (hour < 18) return 'Good afternoon';
    return 'Good evening';
  }
}

class _AvatarBadge extends StatelessWidget {
  const _AvatarBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 52,
      height: 52,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: AppColors.brandGradient,
        border: Border.all(color: AppColors.hairline, width: 2),
      ),
      child: const Center(
        child: Icon(Icons.person_rounded, color: Colors.white, size: 28),
      ),
    );
  }
}
