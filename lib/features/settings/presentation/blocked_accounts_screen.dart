import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../core/utils/extensions.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/app_error_state.dart';
import '../../../shared/widgets/app_scaffold.dart';
import '../../../shared/widgets/glass_card.dart';
import '../../profile_setup/presentation/providers/profile_provider.dart';
import '../data/settings_repository.dart';
import 'providers/settings_providers.dart';
import 'widgets/setting_widgets.dart';

class BlockedAccountsScreen extends ConsumerWidget {
  const BlockedAccountsScreen({super.key});

  Future<void> _unblock(
    WidgetRef ref,
    BuildContext context,
    String blockedId,
  ) async {
    final profile = ref.read(currentProfileProvider).asData?.value;
    if (profile == null) return;
    await ref
        .read(settingsRepositoryProvider)
        .unblockUser(profile.userId, blockedId);
    if (!context.mounted) return;
    context.showSnack(AppLocalizations.of(context).blockedUnblockedSnack);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final blocked = ref.watch(blockedUsersProvider);

    return AppScaffold(
      appBar: AppBar(
        title: Text(l10n.blockedTitle),
        leading: const BackButton(),
      ),
      body: ListView(
        padding: const EdgeInsets.only(top: AppSpacing.md, bottom: 64),
        children: [
          Text(
            l10n.blockedSubtitle,
            style:
                AppTypography.body.copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: AppSpacing.lg),
          blocked.when(
            loading: () => const Padding(
              padding: EdgeInsets.all(AppSpacing.lg),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (e, _) => AppErrorState(
              compact: true,
              message: AppLocalizations.of(context).errorLoadContent,
              onRetry: () => ref.invalidate(blockedUsersProvider),
            ),
            data: (list) {
              if (list.isEmpty) {
                return GlassCard(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.verified_outlined,
                        color: AppColors.bordeauxLight,
                        size: 20,
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Text(
                          l10n.blockedEmpty,
                          style: AppTypography.body
                              .copyWith(color: AppColors.textSecondary),
                        ),
                      ),
                    ],
                  ),
                );
              }
              return SettingSection(
                title: l10n.blockedTitle,
                children: [
                  for (final user in list)
                    SettingTile(
                      icon: Icons.person_off_outlined,
                      title: user.displayName,
                      subtitle: _formatBlockedAt(user.blockedAt, l10n),
                      trailing: TextButton(
                        onPressed: () => _unblock(ref, context, user.id),
                        child: Text(l10n.blockedUnblock),
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  String _formatBlockedAt(DateTime when, AppLocalizations l10n) {
    // `when` arrives as a UTC DateTime (parsed from a Supabase
    // TIMESTAMPTZ via Z-suffixed ISO string). DateTime.difference()
    // is epoch-based so this would actually work even without the
    // explicit .toUtc() — but making the intent explicit prevents
    // future regressions if a caller ever passes a different
    // representation and matches the project-wide "compute in UTC,
    // format at the very edge" convention from the Phase A
    // timezone refactor.
    final diff = DateTime.now().toUtc().difference(when);
    if (diff.inDays >= 30) return '${diff.inDays ~/ 30}m';
    if (diff.inDays >= 1) return '${diff.inDays}d';
    return '${diff.inHours.clamp(1, 23)}h';
  }
}
