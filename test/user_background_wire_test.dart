// The Dart enums and the SQL CHECK constraints are one contract.
//
// `profile_setup_steps_test.dart` pins the enum names against a literal list
// written by hand. That catches a rename in Dart — it cannot catch the two
// files drifting apart, because the SQL was never read. This test reads
// the migration itself, so a value added on one side and forgotten on the
// other fails here rather than in production as a 400 on save.
//
// The failure it guards against is quiet: PostgREST rejects the row, the
// repository logs and swallows (losing a whole signup over an optional
// answer would be worse), and the answer simply never appears again.

import 'dart:io';

import 'package:datenow/features/profile_setup/domain/enums.dart';
import 'package:flutter_test/flutter_test.dart';

const _migration =
    'supabase/migrations/20260819200000_user_background.sql';

/// Pulls the quoted values out of one CHECK clause.
///
/// Deliberately dumb: it takes the text between the column name and the
/// closing paren and collects every 'single-quoted' token. A parser clever
/// enough to be wrong is worse than one that fails loudly.
Set<String> _valuesAfter(String sql, String marker) {
  final start = sql.indexOf(marker);
  expect(start, greaterThan(-1), reason: 'marker "$marker" not found in $_migration');
  final tail = sql.substring(start + marker.length);
  final end = tail.indexOf(')');
  expect(end, greaterThan(-1), reason: 'unterminated CHECK after "$marker"');
  return RegExp(r"'([A-Za-z_]+)'")
      .allMatches(tail.substring(0, end))
      .map((m) => m.group(1)!)
      .toSet();
}

void main() {
  late String sql;

  setUpAll(() {
    final file = File(_migration);
    expect(file.existsSync(), isTrue,
        reason: 'run from the repo root; $_migration must exist');
    sql = file.readAsStringSync();
  });

  test('origins: the ARRAY literal matches Origin.values exactly', () {
    expect(
      _valuesAfter(sql, 'origins <@ ARRAY['),
      Origin.values.map((e) => e.name).toSet(),
    );
  });

  test('religion: the IN list matches Religion.values exactly', () {
    expect(
      _valuesAfter(sql, 'religion IN ('),
      Religion.values.map((e) => e.name).toSet(),
    );
  });

  test('drinking: the IN list matches Drinking.values exactly', () {
    expect(
      _valuesAfter(sql, 'drinking IN ('),
      Drinking.values.map((e) => e.name).toSet(),
    );
  });

  test('smoking: the IN list matches Smoking.values exactly', () {
    expect(
      _valuesAfter(sql, 'smoking IN ('),
      Smoking.values.map((e) => e.name).toSet(),
    );
  });

  test('education: the IN list matches EducationLevel.values exactly', () {
    expect(
      _valuesAfter(sql, 'education IN ('),
      EducationLevel.values.map((e) => e.name).toSet(),
    );
  });

  test('the repository writes the column names the migration declares', () {
    // The values are pinned above; the column names were not. A typo like
    // `education_level` for `education` fails the same silent way: PostgREST
    // 400s, saveProfile logs and swallows, and the answer never comes back.
    const repo = 'lib/features/profile_setup/data/profile_repository.dart';
    final dart = File(repo).readAsStringSync();
    final upsert = dart.substring(dart.indexOf("from('user_background').upsert"));

    for (final column in [
      'origins',
      'religion',
      'drinking',
      'smoking',
      'education',
    ]) {
      expect(sql, contains('  $column '),
          reason: '$column is not a column in $_migration');
      expect(upsert, contains("'$column':"),
          reason: '$repo does not write $column');
      expect(dart, contains("backgroundRow?['$column']"),
          reason: '$repo does not read $column back');
    }
  });

  test('the table is the separate one, not columns on profiles', () {
    // The whole point of the design decision: profiles carries a broad read
    // policy, so article-9 data must not live there.
    expect(sql, contains('CREATE TABLE IF NOT EXISTS public.user_background'));
    expect(sql, contains('ENABLE ROW LEVEL SECURITY'));
    expect(sql, contains('user_background_select_not_blocked'));
    expect(
      sql.contains('ALTER TABLE public.profiles ADD COLUMN'),
      isFalse,
      reason: 'background must never become a column on profiles',
    );
  });
}
