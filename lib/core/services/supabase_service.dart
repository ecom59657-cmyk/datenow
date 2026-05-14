import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/env.dart';
import '../utils/logger.dart';

/// Owns the lifecycle of the Supabase SDK.
///
/// Call [SupabaseService.init] from `main()` before `runApp`. After that,
/// access the singleton client via [Supabase.instance.client] or — preferably —
/// through the [supabaseClientProvider] below so it can be overridden in tests.
class SupabaseService {
  const SupabaseService._();

  static const _log = AppLogger('Supabase');

  static bool _initialized = false;
  static bool get isInitialized => _initialized;

  static Future<void> init() async {
    if (_initialized) return;

    if (!Env.supabaseConfigured) {
      _log.warn(
        'Supabase NOT initialised — SUPABASE_URL and/or SUPABASE_ANON_KEY '
        'are missing from .env. Sign up, sign in and every backend-backed '
        'feature will run against the in-memory mock. Populate .env then '
        'restart the app to talk to the real Supabase project.',
      );
      return;
    }

    try {
      await Supabase.initialize(
        url: Env.supabaseUrl,
        anonKey: Env.supabaseAnonKey,
        authOptions: const FlutterAuthClientOptions(
          authFlowType: AuthFlowType.pkce,
        ),
      );
      _initialized = true;
      _log.info('Supabase initialised at ${Env.supabaseUrl}');
    } catch (e, st) {
      _log.error(
        'Supabase.initialize THREW — env appears set but the SDK refused '
        'to bring up the client. Check your URL + anon key.',
        e,
        st,
      );
      rethrow;
    }
  }
}

/// Exposes the Supabase client to the rest of the app.
///
/// When Supabase keys are absent, this provider throws — features should
/// gate on [supabaseAvailableProvider] before reading it.
final supabaseClientProvider = Provider<SupabaseClient>((ref) {
  if (!SupabaseService.isInitialized) {
    throw StateError(
      'SupabaseService not initialized. Did you forget to call '
      'SupabaseService.init() in main() — or to populate .env?',
    );
  }
  return Supabase.instance.client;
});

final supabaseAvailableProvider = Provider<bool>(
  (_) => SupabaseService.isInitialized,
);
