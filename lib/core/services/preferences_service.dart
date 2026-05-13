import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Async access to [SharedPreferences]. We expose it as a Riverpod
/// [FutureProvider] so features depending on it suspend until the platform
/// channel resolves, instead of having to await it everywhere.
final sharedPreferencesProvider = FutureProvider<SharedPreferences>((ref) {
  return SharedPreferences.getInstance();
});
