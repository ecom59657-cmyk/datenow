import 'package:flutter/material.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../shared/widgets/app_scaffold.dart';
import '../../../shared/widgets/glass_card.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        leading: const BackButton(),
      ),
      body: ListView(
        padding: const EdgeInsets.only(top: AppSpacing.md, bottom: 120),
        physics: const BouncingScrollPhysics(),
        children: const [
          _Section(title: 'Account', tiles: [
            _Tile(icon: Icons.email_outlined, label: 'Email address'),
            _Tile(icon: Icons.password_rounded, label: 'Password'),
            _Tile(icon: Icons.phone_iphone_rounded, label: 'Phone number'),
          ]),
          SizedBox(height: AppSpacing.lg),
          _Section(title: 'Notifications', tiles: [
            _Tile(icon: Icons.notifications_active_outlined, label: 'Push'),
            _Tile(icon: Icons.email_rounded, label: 'Email summaries'),
          ]),
          SizedBox(height: AppSpacing.lg),
          _Section(title: 'Privacy', tiles: [
            _Tile(icon: Icons.shield_outlined, label: 'Block list'),
            _Tile(icon: Icons.history_rounded, label: 'Activity history'),
            _Tile(icon: Icons.description_outlined, label: 'Privacy policy'),
          ]),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.tiles});

  final String title;
  final List<_Tile> tiles;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(
            left: AppSpacing.xs,
            bottom: AppSpacing.xs,
          ),
          child: Text(
            title.toUpperCase(),
            style: AppTypography.overline,
          ),
        ),
        GlassCard(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              for (final (i, tile) in tiles.indexed) ...[
                tile,
                if (i < tiles.length - 1)
                  const Divider(
                    color: AppColors.hairlineSoft,
                    height: 1,
                    indent: AppSpacing.md,
                    endIndent: AppSpacing.md,
                  ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: AppColors.textSecondary),
      title: Text(label, style: AppTypography.bodyLarge),
      trailing: const Icon(
        Icons.chevron_right_rounded,
        color: AppColors.textTertiary,
      ),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: 2,
      ),
      onTap: () {},
    );
  }
}
