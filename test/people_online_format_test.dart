// Pure-logic tests for the Home "personnes en ligne" formatter, mirroring
// available_dates_format_test.dart. The freshness window (60 s, server
// clock) lives in the active_profiles_count() SECURITY DEFINER RPC and is
// covered by supabase/tests/flow_checks.sql. What we pin down here is that
// the tile never invents an audience: loading shows a placeholder,
// error/null/zero all surface the empty messaging instead of a number —
// the exact failure mode that got the old hard-coded "1.2k" flagged.

import 'package:datenow/features/home/presentation/widgets/people_online_display.dart';
import 'package:datenow/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppLocalizations fr;
  late AppLocalizations en;

  setUpAll(() async {
    fr = await AppLocalizations.delegate.load(const Locale('fr'));
    en = await AppLocalizations.delegate.load(const Locale('en'));
  });

  group('formatPeopleOnline — FR', () {
    test('loading shows the placeholder, never a number', () {
      final r = formatPeopleOnline(fr, const AsyncLoading<int?>());
      expect(r.value, '…');
      expect(r.label, 'Personnes en ligne près de vous');
    });

    test('null data → empty messaging (no fake count)', () {
      final r = formatPeopleOnline(fr, const AsyncData<int?>(null));
      expect(r.value, '—');
      expect(r.label, 'Personne en ligne pour l\'instant');
    });

    test('0 → empty messaging, not the literal "0"', () {
      final r = formatPeopleOnline(fr, const AsyncData<int?>(0));
      expect(r.value, '—');
      expect(r.label, 'Personne en ligne pour l\'instant');
    });

    test('1 → singular wording', () {
      final r = formatPeopleOnline(fr, const AsyncData<int?>(1));
      expect(r.value, '1');
      expect(r.label, 'personne en ligne près de vous');
    });

    test('12 → plural wording', () {
      final r = formatPeopleOnline(fr, const AsyncData<int?>(12));
      expect(r.value, '12');
      expect(r.label, 'personnes en ligne près de vous');
    });

    test('error → empty messaging fallback (never a wrong number)', () {
      final r = formatPeopleOnline(
        fr,
        AsyncError<int?>('boom', StackTrace.empty),
      );
      expect(r.value, '—');
      expect(r.label, 'Personne en ligne pour l\'instant');
    });
  });

  group('formatPeopleOnline — EN', () {
    test('1 vs N pluralization', () {
      expect(
        formatPeopleOnline(en, const AsyncData<int?>(1)).label,
        'person online near you',
      );
      expect(
        formatPeopleOnline(en, const AsyncData<int?>(12)).label,
        'people online near you',
      );
    });
  });

  group('date duration tile', () {
    test('renders the product constant, not a measured stat', () {
      expect(fr.dateDurationValue(5), '5 min');
      expect(fr.dateDurationLabel, 'Durée d\'un date vidéo');
      expect(en.dateDurationLabel, 'Length of a video date');
    });
  });
}
