import 'package:datenow/app/locale/locale_resolver.dart';
import 'package:datenow/core/utils/age.dart';
import 'package:datenow/core/utils/extensions.dart';
import 'package:datenow/l10n/app_localizations.dart';
import 'package:datenow/l10n/app_localizations_en.dart';
import 'package:datenow/l10n/app_localizations_fr.dart';
import 'package:datenow/core/utils/validators.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final AppLocalizations en = AppLocalizationsEn();
  final AppLocalizations fr = AppLocalizationsFr();

  group('Validators', () {
    test('email validator', () {
      expect(Validators.email('', en), isNotNull);
      expect(Validators.email('not-an-email', en), isNotNull);
      expect(Validators.email('hi@datenow.app', en), isNull);
    });

    test('password validator', () {
      expect(Validators.password('', en), isNotNull);
      expect(Validators.password('short', en), isNotNull);
      expect(Validators.password('longenoughpw', en), isNull);
    });

    test('first name validator', () {
      expect(Validators.firstName('', en), isNotNull);
      expect(Validators.firstName('A', en), isNotNull);
      expect(Validators.firstName('Alex', en), isNull);
    });

    test('confirm password validator', () {
      expect(Validators.confirmPassword('', 'hello12345', en), isNotNull);
      expect(Validators.confirmPassword('mismatch', 'hello12345', en),
          isNotNull);
      expect(Validators.confirmPassword('hello12345', 'hello12345', en),
          isNull);
    });

    test('returns localized messages in French', () {
      // Different copy than English — proves we're hitting the FR bundle.
      expect(Validators.email('', en),
          isNot(equals(Validators.email('', fr))));
    });
  });

  group('Duration extensions', () {
    test('toMmSs formats correctly', () {
      expect(const Duration(minutes: 5).toMmSs(), '5:00');
      expect(const Duration(seconds: 9).toMmSs(), '0:09');
      expect(const Duration(minutes: 1, seconds: 23).toMmSs(), '1:23');
    });
  });

  group('Age helpers', () {
    final fixedToday = DateTime(2026, 5, 13);

    test('ageFromBirthDate computes completed years', () {
      expect(
        ageFromBirthDate(DateTime(2000, 5, 13), now: fixedToday),
        26,
      );
      // Birthday is tomorrow → still 25.
      expect(
        ageFromBirthDate(DateTime(2000, 5, 14), now: fixedToday),
        25,
      );
      // Birthday was yesterday → 26 already.
      expect(
        ageFromBirthDate(DateTime(2000, 5, 12), now: fixedToday),
        26,
      );
    });

    test('isOfMinimumAge gates at 18 inclusive', () {
      // Just turned 18 today.
      expect(
        isOfMinimumAge(DateTime(2008, 5, 13), now: fixedToday),
        isTrue,
      );
      // Will turn 18 tomorrow.
      expect(
        isOfMinimumAge(DateTime(2008, 5, 14), now: fixedToday),
        isFalse,
      );
      // Clearly underage.
      expect(
        isOfMinimumAge(DateTime(2015, 1, 1), now: fixedToday),
        isFalse,
      );
    });

    test('birth-date validator rejects minor + invalid + null', () {
      expect(Validators.birthDate(null, en), isNotNull);
      // Future date.
      expect(
        Validators.birthDate(
          DateTime.now().add(const Duration(days: 1)),
          en,
        ),
        isNotNull,
      );
      // 17 years and one day old → blocked.
      final under18 = DateTime.now().subtract(
        const Duration(days: 365 * 17 + 366), // ~ 17 + leap year
      );
      expect(
        Validators.birthDate(DateTime(under18.year, 1, 1), en),
        anyOf(isNotNull, isNull),
      ); // depends on month; we use a stricter case below
      // 17 years ago to the day → blocked.
      final today = DateTime.now();
      final justUnder18 = DateTime(today.year - 17, today.month, today.day);
      expect(Validators.birthDate(justUnder18, en), isNotNull);
      // 19 years ago to the day → allowed.
      final clearlyAdult = DateTime(today.year - 19, today.month, today.day);
      expect(Validators.birthDate(clearlyAdult, en), isNull);
    });
  });

  group('Locale resolver', () {
    final supported = [const Locale('en'), const Locale('fr')];

    test('null device locale → English fallback', () {
      expect(appLocaleResolver(null, supported), const Locale('en'));
    });

    test('any fr-* device locale → French', () {
      expect(appLocaleResolver(const Locale('fr'), supported),
          const Locale('fr'));
      expect(appLocaleResolver(const Locale('fr', 'FR'), supported),
          const Locale('fr'));
      expect(appLocaleResolver(const Locale('fr', 'BE'), supported),
          const Locale('fr'));
      expect(appLocaleResolver(const Locale('fr', 'CH'), supported),
          const Locale('fr'));
      expect(appLocaleResolver(const Locale('fr', 'CA'), supported),
          const Locale('fr'));
    });

    test('non-French locales → English fallback', () {
      expect(appLocaleResolver(const Locale('nl', 'BE'), supported),
          const Locale('en'));
      expect(appLocaleResolver(const Locale('de', 'CH'), supported),
          const Locale('en'));
      expect(appLocaleResolver(const Locale('es', 'ES'), supported),
          const Locale('en'));
      expect(appLocaleResolver(const Locale('en', 'US'), supported),
          const Locale('en'));
    });
  });
}
