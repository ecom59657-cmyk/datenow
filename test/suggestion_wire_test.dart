// The wire mapping between `weekly_suggestions` rows and Dart, now that
// suggestions are persisted instead of living in a Map.
//
// Two things break silently in production and are invisible to the
// analyzer: the `call_started` ↔ `callStarted` rename (SQL uses snake_case,
// the enum does not), and the week key, which has to stay a bare
// `YYYY-MM-DD` DATE — send a full ISO timestamp and the
// UNIQUE(user, peer, week) constraint stops recognising rows written from
// another timezone, so the same person gets proposed twice.

import 'package:datenow/features/discover/data/discover_repository.dart';
import 'package:datenow/features/discover/domain/suggestion_status.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('status ↔ wire', () {
    test('call_started survives the round trip', () {
      expect(
        SupabaseDiscoverRepository.statusFromWire('call_started'),
        SuggestionStatus.callStarted,
      );
      expect(
        SupabaseDiscoverRepository.statusToWire(SuggestionStatus.callStarted),
        'call_started',
      );
    });

    test('the other statuses map verbatim', () {
      for (final s in [
        SuggestionStatus.pending,
        SuggestionStatus.dismissed,
        SuggestionStatus.matched,
      ]) {
        final wire = SupabaseDiscoverRepository.statusToWire(s);
        expect(wire, s.name);
        expect(SupabaseDiscoverRepository.statusFromWire(wire), s);
      }
    });

    test('every wire value is one the CHECK constraint allows', () {
      const allowed = {'pending', 'dismissed', 'call_started', 'matched'};
      for (final s in SuggestionStatus.values) {
        expect(allowed, contains(SupabaseDiscoverRepository.statusToWire(s)));
      }
    });

    test('an unknown wire value falls back to pending, never throws', () {
      expect(
        SupabaseDiscoverRepository.statusFromWire('something_new'),
        SuggestionStatus.pending,
      );
      expect(
        SupabaseDiscoverRepository.statusFromWire(null),
        SuggestionStatus.pending,
      );
    });
  });

  group('week key', () {
    test('is a bare DATE, not a timestamp', () {
      final key = SupabaseDiscoverRepository.weekKey(
        DateTime.utc(2026, 8, 17),
      );
      expect(key, '2026-08-17');
      expect(key.contains('T'), isFalse);
    });

    test('is timezone-independent', () {
      // Same instant, two offsets: the constraint must see one week.
      final utc = DateTime.utc(2026, 8, 17, 2);
      final shifted = DateTime.parse('2026-08-17T04:00:00+02:00');
      expect(
        SupabaseDiscoverRepository.weekKey(utc),
        SupabaseDiscoverRepository.weekKey(shifted),
      );
    });
  });
}
