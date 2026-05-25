import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/config/app_config.dart';
import '../core/debug/debug_observer.dart';
import '../core/notifications/notification_service.dart';
import '../features/presence/presentation/presence_controller.dart';
import '../l10n/app_localizations.dart';
import 'locale/locale_resolver.dart';
import 'router/app_router.dart';
import 'theme/app_theme.dart';

/// Root widget. Composes routing + theme + localization; everything else
/// lives in features.
class DateNowApp extends ConsumerWidget {
  const DateNowApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);

    return PresenceScope(
      child: MaterialApp.router(
        title: AppConfig.appName,
        debugShowCheckedModeBanner: false,
        // Global messenger key so NotificationService can surface an
        // in-app snackbar from anywhere without a route's BuildContext.
        scaffoldMessengerKey: rootScaffoldMessengerKey,
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        themeMode: ThemeMode.dark,
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        localeResolutionCallback: (deviceLocale, _) =>
            resolveAppLocale(deviceLocale),
        // debug-observer — discreet test-observation overlay; no-op in release.
        builder: (context, child) => DebugOverlay(child: child ?? const SizedBox()),
      ),
    );
  }
}
