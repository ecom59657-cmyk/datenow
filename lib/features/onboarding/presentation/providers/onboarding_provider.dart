import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/constants/storage_keys.dart';
import '../../../../core/services/preferences_service.dart';

/// Whether the user has finished onboarding at least once. Resolved from
/// [SharedPreferences] at boot; persists across launches so we never replay
/// onboarding after the first run.
final onboardingCompletedProvider = FutureProvider<bool>((ref) async {
  final prefs = await ref.watch(sharedPreferencesProvider.future);
  return prefs.getBool(StorageKeys.onboardingCompleted) ?? false;
});

/// Imperative API used by the onboarding screen on its final step.
class OnboardingController {
  OnboardingController(this._ref);

  final Ref _ref;

  Future<void> complete() async {
    final prefs = await _ref.read(sharedPreferencesProvider.future);
    await prefs.setBool(StorageKeys.onboardingCompleted, true);
    // Bust the cache so the router re-evaluates its redirect.
    _ref.invalidate(onboardingCompletedProvider);
  }

  Future<void> reset() async {
    final prefs = await _ref.read(sharedPreferencesProvider.future);
    await prefs.remove(StorageKeys.onboardingCompleted);
    _ref.invalidate(onboardingCompletedProvider);
  }
}

final onboardingControllerProvider = Provider<OnboardingController>(
  OnboardingController.new,
);
