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
}
