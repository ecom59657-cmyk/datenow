import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';
import 'core/services/supabase_service.dart';
import 'core/utils/logger.dart';

const _log = AppLogger('Bootstrap');

Future<void> main() async {
  // runZonedGuarded swallows uncaught async errors so a single bad future
  // does not take down the whole isolate before we get a chance to log it.
  await runZonedGuarded<Future<void>>(
    () async {
      WidgetsFlutterBinding.ensureInitialized();

      FlutterError.onError = (details) {
        FlutterError.presentError(details);
        _log.error(
          'FlutterError: ${details.exceptionAsString()}',
          details.exception,
          details.stack,
        );
      };

      // DateNow is mobile-first — lock portrait on platforms that honour it.
      // Web ignores this call, which is fine.
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);

      // .env is optional in development: when absent the app falls back to
      // the in-memory mock auth/data path so the UI still boots.
      try {
        await dotenv.load(fileName: '.env');
      } catch (e) {
        _log.warn('.env not loaded ($e) — continuing without it.');
      }

      await SupabaseService.init();

      runApp(const ProviderScope(child: DateNowApp()));
    },
    (error, stack) {
      _log.error('Uncaught zone error', error, stack);
      if (kDebugMode) {
        // Surface in debug so it is not silently swallowed.
        // ignore: avoid_print
        print('Uncaught zone error: $error\n$stack');
      }
    },
  );
}
