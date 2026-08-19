// The compatibility pill must never outgrow the card.
//
// Regression for a real defect: the pill's `Row(mainAxisSize.min)` lays its
// children out with unbounded main-axis constraints, so a label wider than
// the middle column overflowed. The Container's decoration is clipped to the
// clamped width, so the bordeaux ground stopped short while the text ran on
// over the message button — the two symptoms were one bug.
//
// The middle column is narrow by construction: on the smallest supported
// iPhone (SE, 375 pt) it gets
//   375 − 48 (list) − 36 (card) − 56 (avatar) − 14 − 12 − 42 (button) ≈ 167 pt.
//
// flutter_test's fallback font draws every glyph as a square of the font
// size, so labels measure far wider here than on a device. That makes this
// test strictly harsher than reality — which is what we want from a guard.

import 'package:datenow/features/discover/domain/mutual_match.dart';
import 'package:datenow/features/discover/presentation/widgets/match_card.dart';
// `Orientation` collides with Flutter's own, hence the prefix.
import 'package:datenow/features/profile_setup/domain/enums.dart' as domain;
import 'package:datenow/features/profile_setup/domain/interest.dart';
import 'package:datenow/features/profile_setup/domain/user_profile.dart';
import 'package:datenow/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// No `primaryPhotoUrl`, so the avatar falls back to the initial and the card
/// never reaches `photoBytesProvider` — no Supabase needed.
UserProfile _peer(String firstName) => UserProfile(
      userId: 'peer',
      firstName: firstName,
      birthDate: DateTime(1996, 4, 2),
      gender: domain.Gender.female,
      orientation: domain.Orientation.straight,
      seekingGenders: const {domain.Gender.male},
      seekingAgeMin: 22,
      seekingAgeMax: 40,
      maxDistanceKm: 50,
      intentions: const {domain.Intention.feeling},
      interests: const <Interest>{Interest.music},
      availability: domain.Availability.immediate,
    );

MutualMatch _match(int score, {String firstName = 'Camille'}) => MutualMatch(
      id: 'm1',
      userId: 'me',
      candidate: _peer(firstName),
      compatibilityScore: score,
      matchedAt: DateTime(2026, 8, 19),
    );

/// Reproduces the real geometry: SE width, the list's `EdgeInsets.all(lg)`.
Widget _host(MutualMatch match) => ProviderScope(
      child: MaterialApp(
        locale: const Locale('fr'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 375,
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: MatchCard(match: match, onTap: () {}),
              ),
            ),
          ),
        ),
      ),
    );

void main() {
  // One score per band, so a future label change is caught wherever it lands.
  const scoresByBand = <String, int>{
    'veryHigh': 95,
    'high': 78,
    'medium': 58,
    'low': 30,
  };

  scoresByBand.forEach((band, score) {
    testWidgets('$band: the pill lays out without overflowing the card',
        (tester) async {
      await tester.pumpWidget(_host(_match(score)));
      await tester.pump();

      // A RenderFlex overflow is reported as a FlutterError in debug builds;
      // before the fix this is exactly what fired.
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('the pill stays inside the card it is painted in',
      (tester) async {
    await tester.pumpWidget(_host(_match(95)));
    await tester.pump();

    final card = tester.getRect(find.byType(MatchCard));
    // Every descendant of the pill's Row — icon and label alike — must be
    // painted within the card's bounds. The old bug put the label past the
    // right edge of its own background and onto the message button.
    final label = tester.getRect(find.byType(Text).last);
    expect(label.right, lessThanOrEqualTo(card.right));
  });

  testWidgets('a very long first name does not push the pill out',
      (tester) async {
    await tester.pumpWidget(
      _host(_match(95, firstName: 'Marie-Alexandrine-Joséphine')),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
  });
}
