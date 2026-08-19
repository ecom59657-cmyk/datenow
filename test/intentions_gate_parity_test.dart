// The intentions gate exists twice: in Dart for Discover, in SQL for the
// live matcher. Two implementations of one rule is a divergence waiting to
// happen, so both are pinned to the same explicit table.
//
// The SQL side is checked by supabase/tests/mm_intentions_checks.sql, case
// for case, with the same names. If you change one, this file and that one
// must move together — and one of them will fail if you forget.

import 'package:datenow/features/matching/data/matching_service.dart';
import 'package:datenow/features/profile_setup/domain/enums.dart';
import 'package:flutter_test/flutter_test.dart';

bool _ok(Set<Intention> a, Set<Intention> b) =>
    MatchingService.intentionsCompatible(a, b);

void main() {
  group('the one refusal', () {
    test('serious alone vs casual alone is refused', () {
      expect(_ok({Intention.serious}, {Intention.casual}), isFalse);
    });
    test('and the other way round', () {
      expect(_ok({Intention.casual}, {Intention.serious}), isFalse);
    });
  });

  group('overlap always wins', () {
    test('identical intentions pass', () {
      expect(_ok({Intention.serious}, {Intention.serious}), isTrue);
    });
    test('any overlap passes, even alongside the clash', () {
      expect(_ok({Intention.serious, Intention.casual}, {Intention.casual}),
          isTrue);
    });
    test('partial overlap passes', () {
      expect(_ok({Intention.feeling, Intention.talk},
          {Intention.talk, Intention.casual}), isTrue);
    });
  });

  group('silence is not opposition', () {
    test('an empty side passes', () {
      expect(_ok(const {}, {Intention.casual}), isTrue);
    });
    test('the other empty side passes', () {
      expect(_ok({Intention.serious}, const {}), isTrue);
    });
    test('both empty pass', () {
      expect(_ok(const {}, const {}), isTrue);
    });
  });

  group('the middle of the range never blocks', () {
    test('feeling vs casual passes', () {
      expect(_ok({Intention.feeling}, {Intention.casual}), isTrue);
    });
    test('talk vs serious passes', () {
      expect(_ok({Intention.talk}, {Intention.serious}), isTrue);
    });
    test('feeling vs talk passes', () {
      expect(_ok({Intention.feeling}, {Intention.talk}), isTrue);
    });
  });

  group('"exclusively" means exactly one', () {
    test('serious+feeling vs casual passes', () {
      expect(_ok({Intention.serious, Intention.feeling}, {Intention.casual}),
          isTrue);
    });
    test('serious vs casual+talk passes', () {
      expect(_ok({Intention.serious}, {Intention.casual, Intention.talk}),
          isTrue);
    });
  });

  test('the rule is symmetric across every pair', () {
    for (final i in Intention.values) {
      for (final j in Intention.values) {
        expect(_ok({i}, {j}), _ok({j}, {i}),
            reason: 'asymmetric on ${i.name} vs ${j.name}');
      }
    }
  });

  test('exactly 2 of the 16 single-value pairs are refused', () {
    // Pins the blast radius. A change that starts refusing more shows up
    // here rather than as an empty pool in production — which is the failure
    // mode the UX doc warned about: "bloquer trop large viderait le pool".
    var refused = 0;
    for (final i in Intention.values) {
      for (final j in Intention.values) {
        if (!_ok({i}, {j})) refused++;
      }
    }
    expect(refused, 2);
  });

  test('the enum names are the values the SQL gate compares against', () {
    // mm_intentions_compatible hardcodes 'serious' and 'casual'. A rename in
    // Dart would silently disable the server-side gate: the migration would
    // keep comparing against strings nobody writes any more.
    expect(Intention.values.map((e) => e.name).toList(),
        const ['serious', 'feeling', 'talk', 'casual']);
  });
}
