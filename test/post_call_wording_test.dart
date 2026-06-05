// Regression guard for the post-call screen title.
// Old copy "Votre date en direct est terminé" was inconsistent with the
// rest of the app (we say "date vidéo", not "en direct" anywhere else)
// and got cut on small screens. New copy: "Votre date est terminé".

import 'package:datenow/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppLocalizations fr;
  late AppLocalizations en;

  setUpAll(() async {
    fr = await AppLocalizations.delegate.load(const Locale('fr'));
    en = await AppLocalizations.delegate.load(const Locale('en'));
  });

  group('postCallTitle wording', () {
    test('FR is the new shorter copy', () {
      expect(fr.postCallTitle, 'Votre date est terminé 🎉');
    });

    test('EN is the new shorter copy', () {
      expect(en.postCallTitle, 'Your date is over 🎉');
    });

    test('FR no longer carries the old "en direct" wording', () {
      expect(fr.postCallTitle.contains('en direct'), isFalse);
    });

    test('EN no longer carries the old "live date" wording', () {
      expect(en.postCallTitle.contains('live date'), isFalse);
    });
  });
}
