import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';
import 'core/services/supabase_service.dart';
import 'core/utils/logger.dart';

const _log = AppLogger('Bootstrap');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Lock portrait orientation — DateNow is a mobile-first product.
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Load env. Missing file is non-fatal in development: Supabase init will
  // skip itself and the app will still run with mocked auth state.
  try {
    await dotenv.load(fileName: '.env');
  } catch (e) {
    _log.warn('.env not loaded ($e) — continuing without it.');
  }

  await SupabaseService.init();

  runApp(const ProviderScope(child: DateNowApp()));
}
