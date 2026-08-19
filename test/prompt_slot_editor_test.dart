// Widget test for the one interaction that was broken on first ship:
// picking a question has to reveal the text field, immediately, before any
// text exists.
//
// The bug it guards against: the parent only stores answers that carry
// text, so between choosing a question and typing the first character
// there is a state the parent cannot represent. Deriving the field's
// visibility from the parent made that state invisible — you could pick a
// question and nothing happened. No analyzer or unit test sees this; only
// pumping the widget does.

import 'package:datenow/features/profile_setup/domain/prompt.dart';
import 'package:datenow/features/profile_setup/domain/prompt_answer.dart';
import 'package:datenow/features/profile_setup/presentation/widgets/prompt_slot_editor.dart';
import 'package:datenow/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child) => MaterialApp(
      locale: const Locale('fr'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

void main() {
  testWidgets('choosing a question reveals the field with no text yet',
      (tester) async {
    PromptQuestion? reported;
    await tester.pumpWidget(_host(
      PromptSlotEditor(
        answer: null,
        taken: const {},
        onChanged: (q, _) => reported = q,
      ),
    ));

    expect(find.byType(TextField), findsNothing);

    // Open the picker and take the first question.
    await tester.tap(find.byType(InkWell).first);
    await tester.pumpAndSettle();
    final first = PromptQuestion.values.first;
    final l10n = await AppLocalizations.delegate.load(const Locale('fr'));
    await tester.tap(find.text(first.label(l10n)).last);
    await tester.pumpAndSettle();

    expect(reported, first);
    expect(
      find.byType(TextField),
      findsOneWidget,
      reason: 'the answer field must appear as soon as a question is picked',
    );
  });

  testWidgets('an existing answer opens with its text in place',
      (tester) async {
    await tester.pumpWidget(_host(
      PromptSlotEditor(
        answer: const PromptAnswer(
          question: PromptQuestion.perfectSunday,
          answer: 'Un marché, puis rien du tout.',
        ),
        taken: const {},
        onChanged: (_, _) {},
      ),
    ));
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('Un marché, puis rien du tout.'), findsOneWidget);
  });
}
