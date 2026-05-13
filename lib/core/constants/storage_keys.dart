/// Keys used for [SharedPreferences] / secure storage. Centralised so we never
/// have stringly-typed keys floating across features.
class StorageKeys {
  const StorageKeys._();

  static const String onboardingCompleted = 'onboarding_completed_v1';
  static const String lastKnownLocale = 'last_known_locale';
}
