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
        'Supabase env vars missing — skipping init. '
        'Auth and persistence will be disabled.',
      );
      return;
    }

    await Supabase.initialize(
      url: Env.supabaseUrl,
      anonKey: Env.supabaseAnonKey,
      authOptions: const FlutterAuthClientOptions(
        authFlowType: AuthFlowType.pkce,
      ),
    );
    _initialized = true;
    _log.info('Initialized client at ${Env.supabaseUrl}');
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
