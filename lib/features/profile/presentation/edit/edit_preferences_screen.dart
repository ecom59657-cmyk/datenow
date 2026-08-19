import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_spacing.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../core/utils/extensions.dart';
import '../../../../core/utils/logger.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../settings/presentation/widgets/destructive_dialog.dart';
import '../../../../shared/widgets/app_error_state.dart';
import '../../../../shared/widgets/app_button.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../../profile_setup/data/profile_repository.dart';
import '../../../profile_setup/domain/enums.dart';
import '../../../profile_setup/domain/interest.dart';
import '../../../profile_setup/domain/user_profile.dart';
import '../../../profile_setup/presentation/providers/profile_provider.dart';
import '../../../profile_setup/presentation/widgets/choice_card.dart';
import '../../../profile_setup/presentation/widgets/choice_chip_grid.dart';

/// Edits the user's matching criteria: who they're looking for, age range,
/// distance, intentions, interests, availability. Companion of
/// [EditProfileScreen].
class EditPreferencesScreen extends ConsumerStatefulWidget {
  const EditPreferencesScreen({super.key});

  @override
  ConsumerState<EditPreferencesScreen> createState() =>
      _EditPreferencesScreenState();
}

class _EditPreferencesScreenState
    extends ConsumerState<EditPreferencesScreen> {
  // Baseline — re-synced on first load and after each successful save.
  Set<Gender> _initialSeekingGenders = const {};
  int _initialAgeMin = 18;
  int _initialAgeMax = 40;
  int _initialMaxDistance = 50;
  Set<Intention> _initialIntentions = const {};
  Set<Interest> _initialInterests = const {};
  Availability? _initialAvailability;

  // Live draft.
  Set<Gender> _seekingGenders = const {};
  int _ageMin = 18;
  int _ageMax = 40;
  int _maxDistance = 50;
  Set<Intention> _intentions = const {};
  Set<Interest> _interests = const {};
  Availability? _availability;

  bool _loaded = false;
  bool _saving = false;

  void _populateFrom(UserProfile profile) {
    if (_loaded) return;
    _loaded = true;
    _initialSeekingGenders = {...profile.seekingGenders};
    _initialAgeMin = profile.seekingAgeMin;
    _initialAgeMax = profile.seekingAgeMax;
    _initialMaxDistance = profile.maxDistanceKm;
    _initialIntentions = {...profile.intentions};
    _initialInterests = {...profile.interests};
    _initialAvailability = profile.availability;

    _seekingGenders = {..._initialSeekingGenders};
    _ageMin = _initialAgeMin;
    _ageMax = _initialAgeMax;
    _maxDistance = _initialMaxDistance;
    _intentions = {..._initialIntentions};
    _interests = {..._initialInterests};
    _availability = _initialAvailability;
  }

  bool get _isValid =>
      _seekingGenders.isNotEmpty &&
      _intentions.isNotEmpty &&
      _interests.length >= 3 &&
      _availability != null;

  bool get _isDirty =>
      !setEquals(_seekingGenders, _initialSeekingGenders) ||
      _ageMin != _initialAgeMin ||
      _ageMax != _initialAgeMax ||
      _maxDistance != _initialMaxDistance ||
      !setEquals(_intentions, _initialIntentions) ||
      !setEquals(_interests, _initialInterests) ||
      _availability != _initialAvailability;

  static const _log = AppLogger('EditPrefs');

  /// System back / swipe-back with unsaved edits asks first. Nothing in
  /// lib/ used to guard this: a back gesture on a half-filled form threw
  /// the input away silently.
  Future<void> _confirmDiscard(bool didPop) async {
    if (didPop || !_isDirty || !mounted) return;
    final l10n = AppLocalizations.of(context);
    final discard = await showDestructiveConfirm(
      context: context,
      title: l10n.discardChangesTitle,
      body: l10n.discardChangesBody,
      confirmLabel: l10n.discardChangesAction,
    );
    if (!discard || !mounted) return;
    Navigator.of(context).pop();
  }

  Future<void> _save(UserProfile current) async {
    if (!_isValid || !_isDirty) return;
    setState(() => _saving = true);
    final updated = current.copyWith(
      seekingGenders: _seekingGenders,
      seekingAgeMin: _ageMin,
      seekingAgeMax: _ageMax,
      maxDistanceKm: _maxDistance,
      intentions: _intentions,
      interests: _interests,
      availability: _availability,
    );
    try {
      await ref.read(profileRepositoryProvider).saveProfile(updated);
      if (!mounted) return;
      // Re-baseline so the form is clean again.
      setState(() {
      _initialSeekingGenders = {...updated.seekingGenders};
      _initialAgeMin = updated.seekingAgeMin;
      _initialAgeMax = updated.seekingAgeMax;
      _initialMaxDistance = updated.maxDistanceKm;
      _initialIntentions = {...updated.intentions};
        _initialInterests = {...updated.interests};
        _initialAvailability = updated.availability;
      });
      if (!mounted) return;
      context.showSnack(AppLocalizations.of(context).savedSnack);
    } catch (e, st) {
      _log.error('savePreferences failed', e, st);
      if (!mounted) return;
      context.showSnack(AppLocalizations.of(context).errorSaveGeneric);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final profileAsync = ref.watch(currentProfileProvider);

    return profileAsync.when(
      loading: () => const AppScaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => AppScaffold(
        body: AppErrorState(
          message: AppLocalizations.of(context).errorLoadProfile,
          onRetry: () => ref.invalidate(currentProfileProvider),
        ),
      ),
      data: (profile) {
        if (profile == null) return const AppScaffold(body: SizedBox.shrink());
        _populateFrom(profile);

        final canSave = _isValid && _isDirty && !_saving;

        return PopScope(
          canPop: !_isDirty,
          onPopInvokedWithResult: (didPop, _) => _confirmDiscard(didPop),
          child: AppScaffold(
          appBar: AppBar(
            title: Text(l10n.editPreferencesTitle),
            leading: const BackButton(),
          ),
          body: Column(
            children: [
              Expanded(
                child: ListView(
                  padding: EdgeInsets.zero,
                  children: [
                    const SizedBox(height: AppSpacing.md),
                    _Label(l10n.seekingGenderLabel),
                    const SizedBox(height: AppSpacing.sm),
                    ChoiceChipGrid<Gender>(
                      options: Gender.values,
                      labelOf: (g) => g.label(l10n),
                      isSelected: _seekingGenders.contains,
                      onToggle: (g) => setState(() {
                        if (_seekingGenders.contains(g)) {
                          _seekingGenders = {..._seekingGenders}..remove(g);
                        } else {
                          _seekingGenders = {..._seekingGenders, g};
                        }
                      }),
                    ),
                    const SizedBox(height: AppSpacing.xl),
                    _LabelWithValue(
                      l10n.seekingAgeLabel,
                      l10n.ageRangeValue(_ageMin, _ageMax),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    RangeSlider(
                      values: RangeValues(_ageMin.toDouble(), _ageMax.toDouble()),
                      min: 18,
                      max: 80,
                      divisions: 62,
                      activeColor: AppColors.bordeaux,
                      inactiveColor: AppColors.hairline,
                      onChanged: (v) => setState(() {
                        _ageMin = v.start.round();
                        _ageMax = v.end.round();
                      }),
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    _LabelWithValue(
                      l10n.distanceLabel,
                      l10n.distanceValue(_maxDistance),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Slider(
                      value: _maxDistance.toDouble(),
                      min: 5,
                      max: 200,
                      divisions: 39,
                      activeColor: AppColors.bordeaux,
                      inactiveColor: AppColors.hairline,
                      onChanged: (v) =>
                          setState(() => _maxDistance = v.round()),
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    _Label(l10n.intentionsLabel),
                    const SizedBox(height: AppSpacing.sm),
                    for (final intention in Intention.values) ...[
                      ChoiceCard(
                        title: intention.label(l10n),
                        body: intention.body(l10n),
                        icon: _iconFor(intention),
                        selected: _intentions.contains(intention),
                        onTap: () => setState(() {
                          if (_intentions.contains(intention)) {
                            _intentions = {..._intentions}..remove(intention);
                          } else {
                            _intentions = {..._intentions, intention};
                          }
                        }),
                      ),
                      const SizedBox(height: AppSpacing.sm),
                    ],
                    const SizedBox(height: AppSpacing.md),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        _Label(l10n.interestsLabel),
                        Text(
                          l10n.interestsHint,
                          style: AppTypography.caption.copyWith(
                            color: AppColors.textTertiary,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    ChoiceChipGrid<Interest>(
                      options: Interest.values,
                      labelOf: (i) => i.label(l10n),
                      isSelected: _interests.contains,
                      onToggle: (i) => setState(() {
                        if (_interests.contains(i)) {
                          _interests = {..._interests}..remove(i);
                        } else {
                          _interests = {..._interests, i};
                        }
                      }),
                    ),
                    const SizedBox(height: AppSpacing.xl),
                    _Label(l10n.availabilityLabel),
                    const SizedBox(height: AppSpacing.sm),
                    for (final availability in Availability.values) ...[
                      ChoiceCard(
                        title: availability.title(l10n),
                        body: availability.body(l10n),
                        icon: availability == Availability.immediate
                            ? Icons.bolt_rounded
                            : Icons.notifications_active_outlined,
                        selected: _availability == availability,
                        onTap: () =>
                            setState(() => _availability = availability),
                      ),
                      const SizedBox(height: AppSpacing.sm),
                    ],
                    const SizedBox(height: AppSpacing.xxl),
                  ],
                ),
              ),
              AppButton(
                label: l10n.saveAction,
                size: AppButtonSize.large,
                isLoading: _saving,
                onPressed: canSave ? () => _save(profile) : null,
              ),
              const SizedBox(height: AppSpacing.lg),
            ],
          ),
          ),
        );
      },
    );
  }

  IconData _iconFor(Intention i) => switch (i) {
        Intention.serious => Icons.favorite_rounded,
        Intention.feeling => Icons.flutter_dash_rounded,
        Intention.talk => Icons.chat_bubble_outline_rounded,
        Intention.casual => Icons.celebration_outlined,
      };
}

class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: AppTypography.caption.copyWith(
        color: AppColors.textSecondary,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.3,
      ),
    );
  }
}

class _LabelWithValue extends StatelessWidget {
  const _LabelWithValue(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: AppTypography.caption.copyWith(
            color: AppColors.textSecondary,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.3,
          ),
        ),
        Text(value, style: AppTypography.bodyStrong),
      ],
    );
  }
}
