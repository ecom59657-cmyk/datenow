// Pure-logic tests for the Home "dates proposés aujourd'hui" formatter.
// The server-side rules (presence freshness, ban exclusion, busy-peer
// exclusion, block exclusion) are enforced by SECURITY DEFINER RPCs and
// can only be observed end-to-end on a real Supabase project — covered
// by supabase/tests/flow_checks.sql + the 2-phone scenario. What we CAN
// pin down here in flutter_test is that the UI never lies about the
// count: loading shows a placeholder, error/null/zero all surface the
// empty messaging (never a fake number), singular/plural copy is right.

import 'package:datenow/features/home/presentation/widgets/available_dates_display.dart';
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

  group('formatAvailableDates — FR', () {
    test('loading shows the placeholder, never a number', () {
      final r = formatAvailableDates(fr, const AsyncLoading<int?>());
      expect(r.value, '…');
      expect(r.label, 'Dates proposés aujourd\'hui');
    });

    test('null data → empty messaging (no fake count)', () {
      final r = formatAvailableDates(fr, const AsyncData<int?>(null));
      expect(r.value, '—');
      expect(r.label, 'Aucun date disponible pour l\'instant');
    });

    test('0 → empty messaging, not the literal "0"', () {
      final r = formatAvailableDates(fr, const AsyncData<int?>(0));
      expect(r.value, '—');
      expect(r.label, 'Aucun date disponible pour l\'instant');
    });

    test('1 → singular wording', () {
      final r = formatAvailableDates(fr, const AsyncData<int?>(1));
      expect(r.value, '1');
      expect(r.label, 'date proposé aujourd\'hui');
    });

    test('4 → plural wording', () {
      final r = formatAvailableDates(fr, const AsyncData<int?>(4));
      expect(r.value, '4');
      expect(r.label, 'dates proposés aujourd\'hui');
    });

    test('error → empty messaging fallback (never a wrong number)', () {
      final r = formatAvailableDates(
        fr,
        AsyncError<int?>('boom', StackTrace.empty),
      );
      expect(r.value, '—');
      expect(r.label, 'Aucun date disponible pour l\'instant');
    });
  });

  group('formatAvailableDates — EN', () {
    test('1 vs N pluralization', () {
      expect(
        formatAvailableDates(en, const AsyncData<int?>(1)).label,
        'date proposal today',
      );
      expect(
        formatAvailableDates(en, const AsyncData<int?>(4)).label,
        'date proposals today',
      );
    });
  });
}
