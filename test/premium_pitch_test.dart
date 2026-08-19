// When the Premium page is put in front of someone.
//
// Two rules worth pinning down, because both are easy to break by accident
// and neither shows up as a failure — only as a worse product.

import 'dart:io';

import 'package:datenow/features/subscription/data/date_milestone_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('the pitch waits for three completed dates', () {
    test('the threshold is three', () {
      expect(DateMilestoneRepository.pitchAfter, 3);
    });

    test('only ended calls are counted', () {
      // A date launched but never connected stays `waiting`. Counting it
      // would pitch a subscription to someone who has not had a single
      // conversation.
      final src = File(
        'lib/features/subscription/data/date_milestone_repository.dart',
      ).readAsStringSync();
      expect(src, contains(".eq('status', 'ended')"));
    });
  });

  group('the pitch is made once', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('unseen by default', () async {
      final prefs = await SharedPreferences.getInstance();
      expect(PremiumPitchSeen.read(prefs), isFalse);
    });

    test('marking sticks', () async {
      final prefs = await SharedPreferences.getInstance();
      await PremiumPitchSeen.mark(prefs);
      expect(PremiumPitchSeen.read(prefs), isTrue);
    });

    test('it is marked before being shown, not after', () {
      // A paywall that survives a crash or a swipe-away comes back on every
      // launch, which is how an app teaches people to dismiss it unread.
      final src =
          File('lib/features/home/presentation/home_screen.dart').readAsStringSync();
      final body = src.substring(src.indexOf('Future<void> _maybePitchPremium()'));
      final mark = body.indexOf('PremiumPitchSeen.mark');
      final push = body.indexOf('pushNamed');
      expect(mark, greaterThan(-1));
      expect(mark, lessThan(push), reason: 'mark first, then show');
    });

    test('never shown to someone already paying', () {
      final src =
          File('lib/features/home/presentation/home_screen.dart').readAsStringSync();
      final body = src.substring(src.indexOf('Future<void> _maybePitchPremium()'));
      expect(body, contains('isPremium'));
    });
  });

  // -------------------------------------------------------------------------
  // Le pitch appartient au troisieme date, pas a la connexion
  // -------------------------------------------------------------------------
  //
  // Bug vu sur appareil : ouvrir une session sur un compte ayant deja trois
  // dates derriere lui affichait la page d'abonnement par-dessus l'accueil.
  // Le compteur est historique, donc il etait deja au-dessus du seuil des la
  // premiere frame de Home. Le pitch se declenche desormais sur une hausse
  // observee pendant la session, jamais sur un etat herite.
  group('the pitch belongs to the third date, not to the sign-in', () {
    late String src;

    setUpAll(() {
      src = File('lib/features/home/presentation/home_screen.dart')
          .readAsStringSync();
    });

    test('the trigger watches the counter, not the derived flag', () {
      expect(src, contains('ref.listen(completedDatesProvider'));
      expect(
        src.contains('ref.listen(shouldPitchPremiumProvider'),
        isFalse,
        reason: 'that flag is already true on the first frame after sign-in',
      );
    });

    test('the first reading of a session pitches nothing', () {
      final body =
          src.substring(src.indexOf('ref.listen(completedDatesProvider'));
      final block = body.substring(0, body.indexOf('});'));
      expect(block, contains('_countAtEntry == null'));
      expect(block, contains('count <= _countAtEntry!'));
      expect(
        block.indexOf('_countAtEntry = count'),
        lessThan(block.indexOf('addPostFrameCallback')),
        reason: 'the entry count is recorded before anything can be shown',
      );
    });

    test('returning from a date refreshes the counter', () {
      // Nothing else in the app invalidates it. Without this the count is
      // read once per launch and the milestone can never be crossed while
      // the app is open — the pitch would fire only at the next sign-in,
      // which is the bug this group exists for.
      final i = src.indexOf('await context.pushNamed(AppRoute.matching.name)');
      expect(i, greaterThan(-1), reason: 'the date flow must be awaited');
      expect(
        src.substring(i, i + 400),
        contains('ref.invalidate(completedDatesProvider)'),
      );
    });
  });
}
