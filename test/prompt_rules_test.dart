// The prompt bank is a contract split across three places: the Dart enum,
// the CHECK constraint in 20260819180000_user_prompts.sql, and the l10n
// keys. Any of them drifting alone breaks at runtime — an insert rejected
// by Postgres, or a MissingStubError on a label — and none of it is
// visible to the analyzer.

import 'dart:io';

import 'package:datenow/features/profile_setup/domain/prompt.dart';
import 'package:datenow/features/profile_setup/domain/prompt_answer.dart';
import 'package:datenow/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('prompt bank ↔ SQL CHECK', () {
    late String migration;

    setUpAll(() {
      migration =
          File('supabase/migrations/20260819180000_user_prompts.sql')
              .readAsStringSync();
    });

    test('every enum value is allowed by the CHECK constraint', () {
      for (final q in PromptQuestion.values) {
        expect(
          migration.contains("'${q.name}'"),
          isTrue,
          reason: '${q.name} would be rejected on insert',
        );
      }
    });

    test('the CHECK allows nothing the enum does not have', () {
      final inCheck = RegExp(r"'([a-zA-Z]+)'")
          .allMatches(migration)
          .map((m) => m.group(1)!)
          .where((v) => v != 'public' && v != 'pgrst')
          .toSet();
      final names = PromptQuestion.values.map((q) => q.name).toSet();
      // Only assert on the question-shaped values, i.e. those the enum
      // knows: an orphan in the CHECK is a value no client can ever write.
      final orphans = inCheck
          .where((v) => v.length > 4 && !names.contains(v))
          .where((v) => !migration.contains('$v('))
          .toSet();
      expect(orphans, isEmpty);
    });

    test('the answer limit is enforced in SQL, not only in the UI', () {
      expect(migration, contains('length(answer) <= 140'));
      expect(PromptRules.maxAnswerLength, 140);
    });

    test('at most three answers, and the ceiling is structural', () {
      expect(PromptRules.maxAnswered, 3);
      expect(migration, contains('position BETWEEN 0 AND 2'));
    });
  });

  group('labels', () {
    test('every question has a label and a hint, FR and EN', () async {
      for (final locale in const [Locale('fr'), Locale('en')]) {
        final l10n = await AppLocalizations.delegate.load(locale);
        for (final q in PromptQuestion.values) {
          expect(q.label(l10n).trim(), isNotEmpty,
              reason: '${q.name} has no label in $locale');
          expect(q.hint(l10n).trim(), isNotEmpty,
              reason: '${q.name} has no hint in $locale');
        }
      }
    });
  });

  group('PromptAnswer', () {
    test('whitespace does not count as an answer', () {
      const blank = PromptAnswer(
        question: PromptQuestion.perfectSunday,
        answer: '   ',
      );
      expect(blank.isFilled, isFalse);
    });
  });
}
