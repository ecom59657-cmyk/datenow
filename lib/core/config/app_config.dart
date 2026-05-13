/// App-level constants tied to the product, not the runtime environment.
class AppConfig {
  const AppConfig._();

  static const String appName = 'DateNow';
  static const String tagline = 'Live dates, in real time.';

  /// Maximum length of an instant date connection.
  static const Duration maxCallDuration = Duration(minutes: 5);

  /// How often we poll for matches in the matching screen (UI-only placeholder
  /// until realtime is wired through Supabase).
  static const Duration matchPollInterval = Duration(seconds: 2);

  /// Minimum age accepted at sign up.
  static const int minAge = 18;
}
