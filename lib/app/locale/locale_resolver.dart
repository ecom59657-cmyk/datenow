import 'package:flutter/widgets.dart';

import '../../l10n/app_localizations.dart';

/// Maps the device's preferred [Locale] to one of our supported app locales.
///
/// Rule for DateNow:
/// - any `fr-*` device locale → French (covers FR, BE-fr, CH-fr, CA-fr, …)
/// - everything else → English (fallback)
///
/// We intentionally key off the language code only — multilingual countries
/// like Belgium or Switzerland are already disambiguated by the OS via the
/// `languageCode` field (a `nl-BE` device should not get French, only a
/// `fr-BE` device should).
Locale appLocaleResolver(
  Locale? deviceLocale,
  Iterable<Locale> supportedLocales,
) {
  const fallback = Locale('en');

  if (deviceLocale == null) return fallback;

  final isFrench = deviceLocale.languageCode == 'fr';
  final frenchSupported =
      supportedLocales.any((l) => l.languageCode == 'fr');

  if (isFrench && frenchSupported) return const Locale('fr');

  return fallback;
}

/// Convenience wrapper to call inside `MaterialApp.localeResolutionCallback`,
/// using the official supported locales list from generated [AppLocalizations].
Locale resolveAppLocale(Locale? deviceLocale) {
  return appLocaleResolver(deviceLocale, AppLocalizations.supportedLocales);
}
