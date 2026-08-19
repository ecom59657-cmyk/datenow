// Chips must flow, and stay tappable.
//
// Regression: `_Chip` used a Container with `alignment: Alignment.center`.
// A Container given an alignment expands to fill bounded constraints, and
// inside a Wrap that is the whole row — so every option rendered as its own
// full-width line. With 7 orientations it read as an odd list; with the 12
// origins and 11 religions of the background step it was a corridor.

import 'package:datenow/features/profile_setup/presentation/widgets/choice_chip_grid.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(
        body: SizedBox(width: 360, child: child),
      ),
    );

void main() {
  testWidgets('short options share a row instead of stacking', (tester) async {
    await tester.pumpWidget(_host(
      ChoiceChipGrid<String>(
        options: const ['Jamais', 'Souvent', 'Parfois'],
        labelOf: (s) => s,
        isSelected: (_) => false,
        onToggle: (_) {},
      ),
    ));

    final first = tester.getRect(find.text('Jamais'));
    final second = tester.getRect(find.text('Souvent'));
    expect(first.center.dy, moreOrLessEquals(second.center.dy, epsilon: 1),
        reason: 'two short chips must sit on the same line');
    expect(second.left, greaterThan(first.right));
  });

  testWidgets('a chip hugs its label rather than filling the row',
      (tester) async {
    await tester.pumpWidget(_host(
      ChoiceChipGrid<String>(
        options: const ['Europe'],
        labelOf: (s) => s,
        isSelected: (_) => false,
        onToggle: (_) {},
      ),
    ));

    final chip = tester.getRect(find.byType(AnimatedContainer));
    expect(chip.width, lessThan(200),
        reason: 'one short label must not occupy the full 360 pt row');
  });

  testWidgets('the tap target stays at the 48 pt minimum', (tester) async {
    await tester.pumpWidget(_host(
      ChoiceChipGrid<String>(
        options: const ['Europe'],
        labelOf: (s) => s,
        isSelected: (_) => false,
        onToggle: (_) {},
      ),
    ));

    final chip = tester.getRect(find.byType(AnimatedContainer));
    expect(chip.height, greaterThanOrEqualTo(48));
  });

  testWidgets('tapping reports the option', (tester) async {
    final tapped = <String>[];
    await tester.pumpWidget(_host(
      ChoiceChipGrid<String>(
        options: const ['Europe', 'Caraïbes'],
        labelOf: (s) => s,
        isSelected: (_) => false,
        onToggle: tapped.add,
      ),
    ));

    await tester.tap(find.text('Caraïbes'));
    expect(tapped, ['Caraïbes']);
  });
}
