// The settings screens, wired to the columns they actually write.
//
// These three screens spent the whole of production reading defaults and
// refusing every save, because SupabaseSettingsRepository was a stub that
// threw and the provider switched to it the moment Supabase was available.
// Nothing failed loudly: the screens render `?? default`, so they looked
// fine and simply never remembered anything.
//
// A unit test cannot reach a Supabase client, and the interesting failure
// here is not logic anyway — it is a column name that does not exist, which
// only shows up at runtime as a PostgrestException nobody reads. So what is
// checked is the wiring: every column the repository names must exist in the
// migration that creates the table, and the stub must stay gone.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _repo = 'lib/features/settings/data/settings_repository.dart';
const _schema = 'supabase/migrations/20260513120000_initial_schema.sql';

String _src(String p) => File(p).readAsStringSync();

/// The column list of a `CREATE TABLE public.<name>` block.
Set<String> _columnsOf(String table) {
  final sql = _src(_schema);
  final start = sql.indexOf('CREATE TABLE IF NOT EXISTS public.$table');
  expect(start, greaterThan(-1), reason: 'table $table not found');
  final end = sql.indexOf(');', start);
  final body = sql.substring(start, end);
  return {
    for (final m in RegExp(r'^\s{2}([a-z_]+)\s+\S', multiLine: true)
        .allMatches(body))
      m.group(1)!,
  };
}

void main() {
  group('the settings repository is no longer a stub', () {
    test('none of its methods throw UnimplementedError any more', () {
      final src = _src(_repo);
      final start = src.indexOf('class SupabaseSettingsRepository');
      final end = src.indexOf('final settingsRepositoryProvider');
      expect(start, greaterThan(-1));
      expect(src.substring(start, end), isNot(contains('UnimplementedError')),
          reason: 'Notifications, Privacy and Blocked accounts depend on it');
    });

    test('and it is the one production uses', () {
      // The stub was reachable precisely because this switch exists.
      final src = _src(_repo);
      expect(src, contains('supabaseAvailableProvider'));
      expect(src, contains('SupabaseSettingsRepository(ref.watch('));
    });
  });

  group('every column written actually exists', () {
    late Set<String> settings;
    late Set<String> blocked;

    setUpAll(() {
      settings = _columnsOf('user_settings');
      blocked = _columnsOf('blocked_users');
    });

    test('user_settings carries all five notification flags', () {
      for (final c in [
        'push_new_match',
        'push_suggestions',
        'push_messages',
        'email_weekly_digest',
        'email_marketing',
      ]) {
        expect(settings, contains(c));
        expect(_src(_repo), contains("'$c'"), reason: '$c is never written');
      }
    });

    test('user_settings carries all five privacy flags', () {
      for (final c in [
        'show_online',
        'block_screenshots',
        'share_usage_data',
        'marketing_consent',
        'two_factor_enabled',
      ]) {
        expect(settings, contains(c));
        expect(_src(_repo), contains("'$c'"), reason: '$c is never written');
      }
    });

    test('the columns the repository names are all real', () {
      // The other direction: a typo would write a column that does not exist
      // and fail only at runtime, inside a screen that swallows the error.
      final named = RegExp(r"'([a-z_]{4,})':")
          .allMatches(_src(_repo))
          .map((m) => m.group(1)!)
          .toSet()
        ..removeWhere((c) => c == 'user_id' || c == 'updated_at');
      for (final c in named) {
        expect(settings, contains(c), reason: '"$c" is not a user_settings column');
      }
    });

    test('blocked_users has what the list needs', () {
      expect(blocked, containsAll(['user_id', 'blocked_user_id', 'blocked_at']));
      final src = _src(_repo);
      expect(src, contains("'blocked_user_id, blocked_at'"));
    });
  });

  group('the writes are upserts, and the reads survive a missing row', () {
    test('preferences are upserted, not updated', () {
      // Accounts older than the handle_new_user trigger have no row. An
      // UPDATE would match nothing and report success — the shape of a
      // preference that saves and comes back wrong.
      final src = _src(_repo);
      expect(RegExp(r'\.upsert\(').allMatches(src).length, greaterThanOrEqualTo(2));
      expect(src, isNot(contains('.update({')));
    });

    test('an empty result reads as defaults, not as an error', () {
      final src = _src(_repo);
      expect(src, contains('if (rows.isEmpty) return const NotificationPrefs();'));
      expect(src, contains('if (rows.isEmpty) return const PrivacyPrefs();'));
    });

    test('a blocked profile we cannot name is still listed', () {
      // The point of the screen is to unblock, and that needs only the id.
      // Losing the name must not lose the row.
      final src = _src(_repo);
      final fetch = src.indexOf('_fetchBlocked');
      expect(src.substring(fetch), contains('showing ids only'));
    });
  });

  group('the build is submittable', () {
    test('the version is past the published 0.2.0+74', () {
      final v = RegExp(r'^version:\s*(\d+)\.(\d+)\.(\d+)\+(\d+)', multiLine: true)
          .firstMatch(_src('pubspec.yaml'))!;
      final build = int.parse(v.group(4)!);
      expect(build, greaterThan(74),
          reason: 'App Store Connect refuses a build number twice');
    });

    test('export compliance is declared, so it is not asked every upload', () {
      final plist = _src('ios/Runner/Info.plist');
      expect(plist, contains('ITSAppUsesNonExemptEncryption'));
    });
  });
}
