import 'package:flutter_dotenv/flutter_dotenv.dart';

/// Typed accessor for environment variables loaded from `.env` at bootstrap.
///
/// Always read env values through this class — never call [dotenv.env] from
/// features directly. Keeps the surface explicit and makes it trivial to swap
/// the backing store (e.g. `--dart-define`) later.
class Env {
  const Env._();

  static String _required(String key) {
    final value = dotenv.env[key];
    if (value == null || value.isEmpty) {
      throw StateError(
        'Missing required env variable "$key". '
        'Make sure your .env file is present and the asset is loaded.',
      );
    }
    return value;
  }

  static String _optional(String key, {String fallback = ''}) {
    return dotenv.env[key] ?? fallback;
  }

  // Supabase ----------------------------------------------------------------

  static String get supabaseUrl => _required('SUPABASE_URL');
  static String get supabaseAnonKey => _required('SUPABASE_ANON_KEY');

  static bool get supabaseConfigured =>
      (dotenv.env['SUPABASE_URL']?.isNotEmpty ?? false) &&
      (dotenv.env['SUPABASE_ANON_KEY']?.isNotEmpty ?? false);

  // App ---------------------------------------------------------------------

  static String get appEnv => _optional('APP_ENV', fallback: 'development');
  static bool get isProduction => appEnv == 'production';

  // Agora -------------------------------------------------------------------

  /// Public Agora App ID — safe to embed in the client. Project must be
  /// in App-ID-only auth mode for token-less joins to work, or a token
  /// endpoint must sign the join request.
  static String get agoraAppId => _optional('AGORA_APP_ID');
  static bool get agoraConfigured => agoraAppId.isNotEmpty;

  // OAuth — Google ----------------------------------------------------------

  /// REVERSED_CLIENT_ID of the iOS OAuth client created in Google
  /// Cloud Console for `com.datenow.app`. Looks like
  /// `com.googleusercontent.apps.123456789-abc…`. Empty by default —
  /// the Google Sign In button is hidden from the auth landing until
  /// this is set AND the matching scheme is present in
  /// ios/Runner/Info.plist (CFBundleURLTypes). Shipping a placeholder
  /// scheme triggers Apple upload error 90158 ("Invalid URL Scheme."),
  /// so we intentionally feature-flag the feature off rather than
  /// shipping a broken URL scheme.
  ///
  /// Full activation procedure: docs/AUTH_EXTERNAL_CONFIG.md.
  static String get googleReversedClientIdIos =>
      _optional('GOOGLE_REVERSED_CLIENT_ID_IOS');

  /// True once the iOS reversed client ID has been stored in `.env` AND
  /// the matching URL scheme has been added to Info.plist. Drives
  /// whether the "Continue with Google" button renders on AuthLanding +
  /// the "Lier Google" tile is tappable in Security.
  static bool get googleSignInConfigured =>
      googleReversedClientIdIos.isNotEmpty;
}
