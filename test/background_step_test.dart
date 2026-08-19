// The signup background step, driven the way a thumb drives it.
//
// The unit tests prove ProfileDraft can hold and clear these answers. They
// say nothing about whether tapping a chip reaches the draft — which is
// exactly the class of bug that shipped twice on the prompts editor: the
// state was right, the widget never reached it.

import 'package:datenow/features/profile_setup/domain/enums.dart' as domain;
import 'package:datenow/features/profile_setup/presentation/providers/profile_setup_controller.dart';
import 'package:datenow/features/profile_setup/presentation/steps/background_step.dart';
import 'package:datenow/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The step is five chip groups in a ListView. On flutter_test's default
/// 800x600 surface the lower groups are never built, so a test that asks
/// about "Alcool" fails on layout rather than on behaviour. A tall surface
/// puts the whole step in the tree, which is the situation being described.
Future<void> _pumpStep(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(420, 2600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(_host());
  await tester.pumpAndSettle();
}

Widget _host() => const ProviderScope(
      child: MaterialApp(
        locale: Locale('fr'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: BackgroundStep()),
      ),
    );

/// Reads the live draft out of the running widget tree.
ProfileDraft _draft(WidgetTester tester) {
  final element = tester.element(find.byType(BackgroundStep));
  return ProviderScope.containerOf(element)
      .read(profileSetupControllerProvider);
}

Future<void> _tap(WidgetTester tester, String label) async {
  await tester.ensureVisible(find.text(label).first);
  await tester.tap(find.text(label).first, warnIfMissed: false);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the five groups are all there', (tester) async {
    await _pumpStep(tester);
    for (final label in ['Origines', 'Religion', 'Alcool', 'Tabac', 'Études']) {
      expect(find.text(label), findsOneWidget, reason: 'missing group $label');
    }
  });

  testWidgets('the sensitive-data notice is shown before the questions',
      (tester) async {
    await _pumpStep(tester);
    final note = find.textContaining('informations sensibles');
    expect(note, findsOneWidget);

    // Before, not after: consent has to be informed to be consent.
    final noteY = tester.getRect(note).top;
    final firstQuestionY = tester.getRect(find.text('Origines')).top;
    expect(noteY, lessThan(firstQuestionY));
  });

  testWidgets('nothing is selected when the step opens', (tester) async {
    await _pumpStep(tester);
    final d = _draft(tester);
    expect(d.origins, isEmpty);
    expect(d.religion, isNull);
    expect(d.drinking, isNull);
    expect(d.smoking, isNull);
    expect(d.education, isNull);
  });

  testWidgets('tapping a chip reaches the draft', (tester) async {
    await _pumpStep(tester);
    await _tap(tester, 'Bouddhiste');
    expect(_draft(tester).religion, domain.Religion.buddhist);
  });

  testWidgets('tapping the selected chip again takes the answer back',
      (tester) async {
    await _pumpStep(tester);
    await _tap(tester, 'Bouddhiste');
    expect(_draft(tester).religion, domain.Religion.buddhist);

    await _tap(tester, 'Bouddhiste');
    expect(_draft(tester).religion, isNull,
        reason: 'an answer given by accident must be removable on the spot');
  });

  testWidgets('choosing another religion replaces, never accumulates',
      (tester) async {
    await _pumpStep(tester);
    await _tap(tester, 'Catholique');
    await _tap(tester, 'Musulman');
    expect(_draft(tester).religion, domain.Religion.muslim);
  });

  testWidgets('origins accumulate — mixed heritage picks no side',
      (tester) async {
    await _pumpStep(tester);
    await _tap(tester, 'Caraïbes');
    await _tap(tester, 'Europe');
    expect(_draft(tester).origins,
        {domain.Origin.caribbean, domain.Origin.europe});

    await _tap(tester, 'Europe');
    expect(_draft(tester).origins, {domain.Origin.caribbean});
  });

  testWidgets('drinking, smoking and education each record their answer',
      (tester) async {
    await _pumpStep(tester);
    await _tap(tester, 'Jamais');
    await _tap(tester, 'Non-fumeur');
    await _tap(tester, 'Master');

    final d = _draft(tester);
    expect(d.drinking, domain.Drinking.never);
    expect(d.smoking, domain.Smoking.never);
    expect(d.education, domain.EducationLevel.master);
  });

  testWidgets('"Effacer" appears only once there is something to erase',
      (tester) async {
    await _pumpStep(tester);
    expect(find.text('Effacer'), findsNothing);

    await _tap(tester, 'Bouddhiste');
    expect(find.text('Effacer'), findsOneWidget);
  });

  testWidgets('"Effacer" wipes every group at once', (tester) async {
    await _pumpStep(tester);
    await _tap(tester, 'Europe');
    await _tap(tester, 'Catholique');
    await _tap(tester, 'Jamais');
    await _tap(tester, 'Fumeur');
    await _tap(tester, 'Doctorat');

    await _tap(tester, 'Effacer');

    final d = _draft(tester);
    expect(d.origins, isEmpty);
    expect(d.religion, isNull);
    expect(d.drinking, isNull);
    expect(d.smoking, isNull);
    expect(d.education, isNull);
    expect(find.text('Effacer'), findsNothing);
  });

  testWidgets('the step lays out without overflowing', (tester) async {
    await _pumpStep(tester);
    expect(tester.takeException(), isNull);
  });
}
