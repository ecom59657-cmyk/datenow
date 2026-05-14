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

  // Agora -------------------------------------------------------------------

  /// Public App ID. Safe to embed in the client (the cryptographic
  /// privilege lives in the App Certificate, which we keep server-side in
  /// Supabase secrets).
  static String get agoraAppId => _optional('AGORA_APP_ID');

  /// True when an App ID is present *and* Supabase is configured (the
  /// token signer runs as an Edge Function).
  static bool get agoraConfigured =>
      agoraAppId.isNotEmpty && supabaseConfigured;

  // Feature flags / misc ----------------------------------------------------

  static bool get supabaseConfigured =>
      (dotenv.env['SUPABASE_URL']?.isNotEmpty ?? false) &&
      (dotenv.env['SUPABASE_ANON_KEY']?.isNotEmpty ?? false);

  static String get appEnv => _optional('APP_ENV', fallback: 'development');
  static bool get isProduction => appEnv == 'production';
}
