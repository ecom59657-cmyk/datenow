import 'package:flutter/material.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_spacing.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../shared/widgets/glass_card.dart';

/// One section header + grouped tiles. The header is small-caps; tiles are
/// wrapped in a [GlassCard] so they read as a cohesive group.
class SettingSection extends StatelessWidget {
  const SettingSection({
    super.key,
    required this.title,
    required this.children,
  });

  final String title;
  final List<Widget> children;

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
              for (final (i, child) in children.indexed) ...[
                child,
                if (i < children.length - 1)
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

/// Tile used for both navigation entries and one-shot actions. When [danger]
/// is `true` the title + icon switch to the error colour — meant for sign
/// out / delete account.
class SettingTile extends StatelessWidget {
  const SettingTile({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.danger = false,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final color = danger ? AppColors.error : AppColors.textPrimary;
    return ListTile(
      onTap: onTap,
      // Tint chip with a bordeaux glyph, like every other icon chip in the
      // app. On paper the old recipe — white fill, hairline border, grey
      // glyph — rendered as an empty box: the chip was white on white and
      // the icon nearly vanished.
      leading: Container(
        width: 36,
        height: 36,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: danger ? AppColors.errorTint : AppColors.tint,
          borderRadius: AppRadius.brSm,
        ),
        child: Icon(
          icon,
          size: 18,
          color: danger ? AppColors.error : AppColors.bordeaux,
        ),
      ),
      title: Text(
        title,
        style: AppTypography.bodyStrong.copyWith(color: color),
      ),
      subtitle: subtitle == null
          ? null
          : Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                subtitle!,
                style: AppTypography.caption,
              ),
            ),
      trailing: trailing ??
          (onTap == null
              ? null
              : const Icon(
                  Icons.chevron_right_rounded,
                  color: AppColors.textTertiary,
                )),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: 4,
      ),
    );
  }
}

/// Switch-bearing tile. Use in Notifications / Privacy / Security screens.
class SettingSwitchTile extends StatelessWidget {
  const SettingSwitchTile({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SettingTile(
      icon: icon,
      title: title,
      subtitle: subtitle,
      onTap: () => onChanged(!value),
      trailing: Switch.adaptive(
        value: value,
        activeTrackColor: AppColors.bordeaux,
        onChanged: onChanged,
      ),
    );
  }
}
