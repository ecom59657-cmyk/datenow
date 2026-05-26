import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../core/services/location_service.dart';
import '../../../core/utils/extensions.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/app_scaffold.dart';
import '../../profile_setup/presentation/providers/profile_provider.dart';
import '../data/settings_repository.dart';
import '../domain/settings_models.dart';
import 'providers/settings_providers.dart';
import 'widgets/setting_widgets.dart';

class PrivacyScreen extends ConsumerWidget {
  const PrivacyScreen({super.key});

  Future<void> _update(
    WidgetRef ref,
    BuildContext context,
    PrivacyPrefs Function(PrivacyPrefs) f,
  ) async {
    final profile = ref.read(currentProfileProvider).asData?.value;
    if (profile == null) return;
    final repo = ref.read(settingsRepositoryProvider);
    final current =
        ref.read(privacyPrefsProvider).asData?.value ?? const PrivacyPrefs();
    await repo.updatePrivacyPrefs(profile.userId, f(current));
    if (!context.mounted) return;
    context.showSnack(AppLocalizations.of(context).savedSnack);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final prefs =
        ref.watch(privacyPrefsProvider).asData?.value ?? const PrivacyPrefs();

    return AppScaffold(
      appBar: AppBar(
        title: Text(l10n.privacyTitle),
        leading: const BackButton(),
      ),
      body: ListView(
        padding: const EdgeInsets.only(top: AppSpacing.md, bottom: 64),
        children: [
          Text(
            l10n.privacySubtitle,
            style:
                AppTypography.body.copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: AppSpacing.lg),
          // Phase 1.1 of the matching refactor: location consent tile.
          // Putting it here (not in onboarding) keeps the introduction
          // of the new permission discoverable but optional. The live
          // matching flow continues to work without location until the
          // cutover lands in Phase 1.5.
          SettingSection(
            title: l10n.privacyLocationSection,
            children: const [_LocationTile()],
          ),
          const SizedBox(height: AppSpacing.lg),
          SettingSection(
            title: l10n.privacyTitle,
            children: [
              SettingSwitchTile(
                icon: Icons.visibility_outlined,
                title: l10n.privacyShowOnline,
                subtitle: l10n.privacyShowOnlineBody,
                value: prefs.showOnline,
                onChanged: (v) => _update(
                  ref,
                  context,
                  (p) => p.copyWith(showOnline: v),
                ),
              ),
              SettingSwitchTile(
                icon: Icons.no_photography_outlined,
                title: l10n.privacyBlockScreenshots,
                subtitle: l10n.privacyBlockScreenshotsBody,
                value: prefs.blockScreenshots,
                onChanged: (v) => _update(
                  ref,
                  context,
                  (p) => p.copyWith(blockScreenshots: v),
                ),
              ),
              SettingSwitchTile(
                icon: Icons.bar_chart_rounded,
                title: l10n.privacyShareUsage,
                subtitle: l10n.privacyShareUsageBody,
                value: prefs.shareUsageData,
                onChanged: (v) => _update(
                  ref,
                  context,
                  (p) => p.copyWith(shareUsageData: v),
                ),
              ),
              SettingSwitchTile(
                icon: Icons.campaign_outlined,
                title: l10n.privacyMarketing,
                subtitle: l10n.privacyMarketingBody,
                value: prefs.marketingConsent,
                onChanged: (v) => _update(
                  ref,
                  context,
                  (p) => p.copyWith(marketingConsent: v),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Location consent + manual refresh entry. The whole point of this
/// tile during Phase 1.1 is two-fold:
///  1) Let the user grant location permission without buried navigation
///     (the live-matching surface won't trigger it itself until 1.5).
///  2) Provide a debug-friendly "Mettre à jour ma position" action so
///     we can confirm end-to-end that captured coords land in the
///     `profiles.location` column.
class _LocationTile extends ConsumerStatefulWidget {
  const _LocationTile();

  @override
  ConsumerState<_LocationTile> createState() => _LocationTileState();
}

class _LocationTileState extends ConsumerState<_LocationTile> {
  LocationPermission? _permission;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refreshStatus();
  }

  Future<void> _refreshStatus() async {
    final p = await LocationService.instance.currentPermissionStatus();
    if (!mounted) return;
    setState(() => _permission = p);
  }

  Future<void> _onTap() async {
    final l10n = AppLocalizations.of(context);
    final perm = _permission ??
        await LocationService.instance.currentPermissionStatus();

    // Denied-forever → can't re-prompt programmatically. Send the
    // user to the iOS Settings screen.
    if (perm == LocationPermission.deniedForever) {
      await openAppSettings();
      await _refreshStatus();
      return;
    }

    setState(() => _busy = true);
    final result = await LocationService.instance.captureAndPush(force: true);
    if (!mounted) return;
    setState(() => _busy = false);
    await _refreshStatus();
    if (!mounted) return;
    switch (result) {
      case LocationCaptured():
        context.showSnack(l10n.privacyLocationUpdatedSnack);
      case LocationServicesOff():
        context.showSnack(l10n.privacyLocationServicesOff);
      case LocationDenied():
        context.showSnack(l10n.privacyLocationDeniedSnack);
      case LocationFailed():
        context.showSnack(l10n.privacyLocationFailedSnack);
    }
  }

  String _subtitleFor(AppLocalizations l10n) {
    switch (_permission) {
      case LocationPermission.always:
      case LocationPermission.whileInUse:
        return l10n.privacyLocationStatusGranted;
      case LocationPermission.denied:
        return l10n.privacyLocationStatusDenied;
      case LocationPermission.deniedForever:
        return l10n.privacyLocationStatusDeniedForever;
      case LocationPermission.unableToDetermine:
      case null:
        return l10n.privacyLocationStatusUnknown;
    }
  }

  bool get _isGranted =>
      _permission == LocationPermission.always ||
      _permission == LocationPermission.whileInUse;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return SettingTile(
      icon: Icons.my_location_rounded,
      title: l10n.privacyLocationTitle,
      subtitle: _subtitleFor(l10n),
      onTap: _busy ? null : _onTap,
      trailing: _busy
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : _isGranted
              ? const Icon(
                  Icons.refresh_rounded,
                  color: AppColors.textSecondary,
                )
              : null,
    );
  }
}
