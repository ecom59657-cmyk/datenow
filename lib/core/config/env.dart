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
}
